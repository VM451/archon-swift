import Foundation
import MCP

/// Archon policy adapter over the official Model Context Protocol Swift SDK.
///
/// The official SDK owns MCP wire types, protocol negotiation, and transport
/// behavior. Archon keeps its own `MCPTransport`, risk classification, typed
/// errors, and host permission boundary so callers do not depend on vendor
/// types. Authentication remains a consuming-app responsibility through
/// already-resolved request headers; credentials are never discovered or
/// persisted by this adapter.
public actor OfficialMCPTransport: MCPTransport {
    public let endpoint: URL

    private let client: MCP.Client
    private let transport: MCP.HTTPClientTransport
    private var connected = false
    private var progressContinuations: [MCP.ProgressToken: AsyncThrowingStream<MCPStreamEvent, Error>.Continuation] = [:]
    private var activeRequestIDs: Set<MCP.ID> = []

    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        headers: [String: String] = [:],
        streaming: Bool = true,
        requestTimeout: TimeInterval? = 60,
        clientName: String = "Archon",
        clientVersion: String = "1.0"
    ) {
        self.endpoint = endpoint

        // Do not mutate a configuration owned by the consuming application.
        // URLSessionConfiguration is reference-backed on Apple platforms, so
        // the adapter must apply its timeout to an isolated copy.
        let sessionConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        // Preserve custom URL protocol handlers on the isolated configuration.
        // This is required for host-owned networking policies and deterministic
        // test fixtures; assigning the array does not mutate the caller's copy.
        sessionConfiguration.protocolClasses = configuration.protocolClasses
        if let requestTimeout {
            sessionConfiguration.timeoutIntervalForRequest = max(requestTimeout, 0)
        }

        let requestModifier: (URLRequest) -> URLRequest = { request in
            var request = request
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            return request
        }

        self.transport = MCP.HTTPClientTransport(
            endpoint: endpoint,
            configuration: sessionConfiguration,
            streaming: streaming,
            requestModifier: requestModifier
        )
        self.client = MCP.Client(name: clientName, version: clientVersion)
    }

    public func connect() async throws {
        do {
            _ = try await client.connect(transport: transport)
            await client.onNotification(MCP.ProgressNotification.self) { [weak self] message in
                guard let self else { return }
                await self.route(progress: message.params)
            }
            connected = true
        } catch {
            throw Self.mapped(error)
        }
    }

    public func disconnect() async {
        // Cancel request contexts while the client connection is still live.
        // The official SDK keeps the HTTP request task separate from its
        // message loop; merely finishing the Archon stream can otherwise leave
        // an in-flight POST waiting for a server response.
        let requestIDs = Array(activeRequestIDs)
        for requestID in requestIDs {
            try? await client.cancelRequest(
                requestID,
                reason: "The Archon MCP transport is disconnecting."
            )
        }
        activeRequestIDs.removeAll()
        for continuation in progressContinuations.values {
            continuation.finish(throwing: CancellationError())
        }
        progressContinuations.removeAll()
        await client.disconnect()
        connected = false
    }

    public func listTools() async throws -> [MCPTool] {
        try requireConnection()
        do {
            var tools: [MCPTool] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await client.listTools(cursor: cursor)
                tools.append(contentsOf: try page.tools.map(Self.archonTool(from:)))
                guard let nextCursor = page.nextCursor else { break }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw MCPTransportError.invalidResponse
                }
                cursor = nextCursor
            } while true
            return tools
        } catch {
            throw Self.mapped(error)
        }
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        try requireConnection()
        do {
            return try await callToolWithRequestContext(
                name: name,
                arguments: arguments,
                progressToken: nil
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    public func streamTool(
        name: String,
        arguments: [String: JSONValue]
    ) async -> AsyncThrowingStream<MCPStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        guard connected else {
            continuation.finish(throwing: MCPTransportError.notConnected)
            return stream
        }

        let progressToken = MCP.ProgressToken.unique()
        progressContinuations[progressToken] = continuation
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: MCPTransportError.notConnected)
                return
            }
            do {
                let result = try await self.callToolWithRequestContext(
                    name: name,
                    arguments: arguments,
                    progressToken: progressToken
                )
                continuation.yield(.result(result))
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.mapped(error))
            }
            await self.removeProgressContinuation(progressToken)
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { await self?.removeProgressContinuation(progressToken) }
        }
        return stream
    }

    public func listResources() async throws -> [MCPResource] {
        try requireConnection()
        do {
            var resources: [MCPResource] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await client.listResources(cursor: cursor)
                resources.append(contentsOf: page.resources.map {
                    MCPResource(
                        id: $0.uri,
                        uri: $0.uri,
                        name: $0.name,
                        description: $0.description ?? "",
                        mimeType: $0.mimeType
                    )
                })
                guard let nextCursor = page.nextCursor else { break }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw MCPTransportError.invalidResponse
                }
                cursor = nextCursor
            } while true
            return resources
        } catch {
            throw Self.mapped(error)
        }
    }

    public func readResource(uri: String) async throws -> [MCPResourceContent] {
        try requireConnection()
        do {
            return try await client.readResource(uri: uri).map {
                MCPResourceContent(
                    uri: $0.uri,
                    mimeType: $0.mimeType,
                    text: $0.text,
                    blob: $0.blob
                )
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    public func listPrompts() async throws -> [MCPPrompt] {
        try requireConnection()
        do {
            var prompts: [MCPPrompt] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await client.listPrompts(cursor: cursor)
                prompts.append(contentsOf: page.prompts.map(Self.archonPrompt(from:)))
                guard let nextCursor = page.nextCursor else { break }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw MCPTransportError.invalidResponse
                }
                cursor = nextCursor
            } while true
            return prompts
        } catch {
            throw Self.mapped(error)
        }
    }

    public func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        try requireConnection()
        do {
            let result = try await client.getPrompt(
                name: name,
                arguments: arguments.isEmpty ? nil : arguments
            )
            return MCPPromptResult(
                description: result.description,
                messages: result.messages.map(Self.archonPromptMessage(from:))
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    private func requireConnection() throws {
        guard connected else { throw MCPTransportError.notConnected }
    }

    private func callToolWithRequestContext(
        name: String,
        arguments: [String: JSONValue],
        progressToken: MCP.ProgressToken?
    ) async throws -> MCPToolResult {
        try requireConnection()
        let metadata = progressToken.map { MCP.Metadata(progressToken: $0) }
        let context: MCP.RequestContext<MCP.CallTool.Result> = try await client.callTool(
            name: name,
            arguments: arguments.mapValues(Self.mcpValue(from:)),
            meta: metadata
        )
        activeRequestIDs.insert(context.requestID)

        defer {
            activeRequestIDs.remove(context.requestID)
        }
        let result = try await withTaskCancellationHandler {
            try await context.value
        } onCancel: {
            Task {
                try? await client.cancelRequest(
                    context.requestID,
                    reason: "The Archon stream consumer was cancelled."
                )
            }
        }
        return Self.archonToolResult(from: result)
    }

    private func route(progress: MCP.ProgressNotification.Parameters) {
        guard let continuation = progressContinuations[progress.progressToken] else {
            return
        }

        var parameters: [String: JSONValue] = [
            "progressToken": Self.jsonValue(from: progress.progressToken),
            "progress": .number(progress.progress)
        ]
        if let total = progress.total {
            parameters["total"] = .number(total)
        }
        if let message = progress.message {
            parameters["message"] = .string(message)
        }
        continuation.yield(
            .notification(
                method: MCP.ProgressNotification.name,
                params: .object(parameters)
            )
        )
    }

    private func removeProgressContinuation(_ token: MCP.ProgressToken) {
        progressContinuations[token] = nil
    }

    private nonisolated static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? MCPTransportError { return error }
        if let error = error as? MCP.MCPError {
            switch error {
            case .methodNotFound(let message):
                return MCPTransportError.serverError(code: error.code, message: message ?? "Method not found")
            case .invalidParams(let message):
                return MCPTransportError.serverError(code: error.code, message: message ?? "Invalid params")
            case .serverError(let code, let message):
                return MCPTransportError.serverError(code: code, message: message)
            case .connectionClosed:
                return MCPTransportError.notConnected
            case .transportError(let underlying):
                return Self.mapped(underlying)
            default:
                return MCPTransportError.sdkFailure(error.localizedDescription)
            }
        }
        return MCPTransportError.sdkFailure(error.localizedDescription)
    }

    private static func archonTool(from tool: MCP.Tool) throws -> MCPTool {
        guard case .object(let schema) = tool.inputSchema else {
            throw MCPTransportError.invalidResponse
        }

        let risk: MCPRisk
        if tool.annotations.readOnlyHint == true {
            risk = .read
        } else if tool.annotations.destructiveHint == true {
            risk = .destructive
        } else if tool.annotations.openWorldHint == true {
            risk = .external
        } else {
            risk = .modify
        }

        return MCPTool(
            id: tool.name,
            name: tool.name,
            description: tool.description ?? "",
            inputSchema: schema.mapValues(Self.jsonValue(from:)),
            risk: risk,
            title: tool.title,
            outputSchema: tool.outputSchema.flatMap {
                guard case .object(let schema) = $0 else { return nil }
                return schema.mapValues(Self.jsonValue(from:))
            }
        )
    }

    private static func archonPrompt(from prompt: MCP.Prompt) -> MCPPrompt {
        MCPPrompt(
            id: prompt.name,
            name: prompt.name,
            title: prompt.title,
            description: prompt.description ?? "",
            arguments: prompt.arguments?.map {
                MCPPromptArgument(
                    name: $0.name,
                    title: $0.title,
                    description: $0.description,
                    required: $0.required
                )
            } ?? []
        )
    }

    private static func archonPromptMessage(from message: MCP.Prompt.Message) -> MCPPromptMessage {
        MCPPromptMessage(
            role: message.role.rawValue,
            content: jsonValue(from: message.content)
        )
    }

    private static func archonToolResult(
        from result: MCP.CallTool.Result
    ) -> MCPToolResult {
        MCPToolResult(
            content: result.content.map(Self.jsonValue(from:)),
            isError: result.isError ?? false,
            structuredContent: result.structuredContent.map(Self.jsonValue(from:))
        )
    }

    private static func mcpValue(from value: JSONValue) -> MCP.Value {
        switch value {
        case .string(let value): .string(value)
        case .number(let value): .double(value)
        case .bool(let value): .bool(value)
        case .array(let values): .array(values.map(Self.mcpValue(from:)))
        case .object(let values): .object(values.mapValues(Self.mcpValue(from:)))
        case .null: .null
        }
    }

    private static func jsonValue(from value: MCP.Value) -> JSONValue {
        switch value {
        case .null: .null
        case .bool(let value): .bool(value)
        case .int(let value): .number(Double(value))
        case .double(let value): .number(value)
        case .string(let value): .string(value)
        case .data(_, let data): .string(data.base64EncodedString())
        case .array(let values): .array(values.map(Self.jsonValue(from:)))
        case .object(let values): .object(values.mapValues(Self.jsonValue(from:)))
        }
    }

    private static func jsonValue(from token: MCP.ProgressToken) -> JSONValue {
        switch token {
        case .string(let value): .string(value)
        case .integer(let value): .number(Double(value))
        }
    }

    private static func jsonValue(from content: MCP.Tool.Content) -> JSONValue {
        switch content {
        case .text(let text, _, _):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mimeType, _, _):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .audio(let data, let mimeType, _, _):
            return .object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .resource(let resource, _, _):
            return .object([
                "type": .string("resource"),
                "resource": jsonValue(from: resource)
            ])
        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            var value: [String: JSONValue] = [
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name)
            ]
            if let title { value["title"] = .string(title) }
            if let description { value["description"] = .string(description) }
            if let mimeType { value["mimeType"] = .string(mimeType) }
            return .object(value)
        }
    }

    private static func jsonValue(from content: MCP.Prompt.Message.Content) -> JSONValue {
        switch content {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .audio(let data, let mimeType):
            return .object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .resource(let resource, _, _):
            return .object([
                "type": .string("resource"),
                "resource": jsonValue(from: resource)
            ])
        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            var value: [String: JSONValue] = [
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name)
            ]
            if let title { value["title"] = .string(title) }
            if let description { value["description"] = .string(description) }
            if let mimeType { value["mimeType"] = .string(mimeType) }
            return .object(value)
        }
    }

    private static func jsonValue(from content: MCP.Resource.Content) -> JSONValue {
        var value: [String: JSONValue] = [
            "uri": .string(content.uri)
        ]
        if let mimeType = content.mimeType { value["mimeType"] = .string(mimeType) }
        if let text = content.text { value["text"] = .string(text) }
        if let blob = content.blob { value["blob"] = .string(blob) }
        return .object(value)
    }
}
