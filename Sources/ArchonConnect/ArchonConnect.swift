import Foundation
import ArchonCore

public struct MCPTool: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let inputSchema: [String: JSONValue]
    public let risk: MCPRisk
    public let title: String?
    public let outputSchema: [String: JSONValue]?

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        inputSchema: [String: JSONValue] = [:],
        risk: MCPRisk = .read,
        title: String? = nil,
        outputSchema: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.risk = risk
        self.title = title
        self.outputSchema = outputSchema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? name,
            name: name,
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            inputSchema: try container.decodeIfPresent([String: JSONValue].self, forKey: .inputSchema) ?? [:],
            risk: try container.decodeIfPresent(MCPRisk.self, forKey: .risk) ?? .read,
            title: try container.decodeIfPresent(String.self, forKey: .title),
            outputSchema: try container.decodeIfPresent([String: JSONValue].self, forKey: .outputSchema)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, inputSchema, risk, title, outputSchema
    }

    /// Validates the common JSON Schema subset used by MCP tool definitions
    /// before arguments reach a remote server.
    public func validate(arguments: [String: JSONValue]) throws {
        try MCPJSONSchemaValidator.validate(
            value: .object(arguments),
            schema: .object(inputSchema),
            path: name
        )
    }
}

public enum MCPRisk: String, Codable, CaseIterable, Sendable {
    case read
    case modify
    case sensitive
    case destructive
    case external
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct MCPToolResult: Codable, Equatable, Sendable {
    public let content: [JSONValue]
    public let isError: Bool
    public let structuredContent: JSONValue?

    public init(
        content: [JSONValue],
        isError: Bool = false,
        structuredContent: JSONValue? = nil
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
    }
}

/// One message observed while consuming an MCP streamable-HTTP response.
/// Progress and supported server notifications are surfaced instead of being
/// discarded while the client waits for the final tool result.
public enum MCPStreamEvent: Equatable, Sendable {
    case result(MCPToolResult)
    case notification(method: String, params: JSONValue?)
}

/// A resource advertised by an MCP server. The wire protocol identifies a
/// resource by URI; `id` is a stable local identity for Swift collection APIs.
public struct MCPResource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: String?

    public init(
        id: String? = nil,
        uri: String,
        name: String,
        description: String = "",
        mimeType: String? = nil
    ) {
        self.id = id ?? uri
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? uri,
            uri: uri,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? uri,
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, uri, name, description, mimeType
    }
}

/// One content item returned by `resources/read`. Text is UTF-8 text and blob
/// is a base64-encoded binary payload as defined by MCP.
public struct MCPResourceContent: Codable, Equatable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public struct MCPPromptArgument: Codable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let required: Bool?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        required: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

public struct MCPPrompt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let title: String?
    public let description: String
    public let arguments: [MCPPromptArgument]

    public init(
        id: String? = nil,
        name: String,
        title: String? = nil,
        description: String = "",
        arguments: [MCPPromptArgument] = []
    ) {
        self.id = id ?? name
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: JSONValue

    public init(role: String, content: JSONValue) {
        self.role = role
        self.content = content
    }
}

public struct MCPPromptResult: Codable, Equatable, Sendable {
    public let description: String?
    public let messages: [MCPPromptMessage]

    public init(description: String? = nil, messages: [MCPPromptMessage] = []) {
        self.description = description
        self.messages = messages
    }
}

public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult
    func streamTool(name: String, arguments: [String: JSONValue]) async -> AsyncThrowingStream<MCPStreamEvent, Error>
    func listResources() async throws -> [MCPResource]
    func readResource(uri: String) async throws -> [MCPResourceContent]
    func listPrompts() async throws -> [MCPPrompt]
    func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult
}

public extension MCPTransport {
    /// Adapts a transport with no native stream to a one-result stream.
    func streamTool(name: String, arguments: [String: JSONValue]) async -> AsyncThrowingStream<MCPStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        do {
            continuation.yield(.result(try await callTool(name: name, arguments: arguments)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }

    func listResources() async throws -> [MCPResource] { [] }

    func readResource(uri: String) async throws -> [MCPResourceContent] {
        throw MCPTransportError.unsupported("resources/read")
    }

    func listPrompts() async throws -> [MCPPrompt] {
        throw MCPTransportError.unsupported("prompts/list")
    }

    func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        throw MCPTransportError.unsupported("prompts/get")
    }
}

public protocol MCPPermissionPolicy: Sendable {
    func allows(_ risk: MCPRisk, tool: MCPTool) async -> Bool
}

public enum MCPTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpFailure(Int)
    case serverError(code: Int, message: String)
    case notConnected
    case unsupported(String)
    case timeout(TimeInterval)
    case invalidArguments(String)
    case sdkFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "MCP returned an invalid JSON-RPC response."
        case .httpFailure(let statusCode): "MCP server returned HTTP \(statusCode)."
        case .serverError(let code, let message): "MCP JSON-RPC error \(code): \(message)"
        case .notConnected: "The MCP HTTP transport is not connected."
        case .unsupported(let operation): "This MCP transport does not support \(operation)."
        case .timeout(let seconds): "MCP request timed out after \(seconds) seconds."
        case .invalidArguments(let reason): "MCP tool arguments are invalid: \(reason)"
        case .sdkFailure(let reason): "The official MCP Swift SDK failed: \(reason)"
        }
    }

    fileprivate var isMethodNotFound: Bool {
        if case .serverError(let code, _) = self { return code == -32601 }
        return false
    }
}

/// JSON-RPC MCP transport for HTTP or streamable-HTTP servers.
///
/// Authentication is supplied as an already-resolved header value so this
/// package never persists, prints, or discovers credentials. A consuming app
/// can obtain a bearer token from its own Keychain-backed credential service.
public actor MCPHTTPTransport: MCPTransport {
    public let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private let protocolVersion: String
    private let clientName: String
    private let clientVersion: String
    private let requestTimeout: TimeInterval?
    private var nextRequestID = 1
    private var sessionID: String?
    private var connected = false
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        protocolVersion: String = "2025-06-18",
        clientName: String = "Archon",
        clientVersion: String = "1.0",
        requestTimeout: TimeInterval? = 60
    ) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout.map { max($0, 0) }
    }

    public func connect() async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])
        _ = try await sendRequest(method: "initialize", params: params)
        try await sendNotification(method: "notifications/initialized")
        connected = true
    }

    public func disconnect() async {
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
        connected = false
        sessionID = nil
    }

    public func listTools() async throws -> [MCPTool] {
        guard connected else { throw MCPTransportError.notConnected }
        let result = try await sendRequest(method: "tools/list", params: .object([:]))
        guard case .object(let object) = result,
              case .array(let values) = object["tools"] else {
            throw MCPTransportError.invalidResponse
        }
        return try values.map { value in
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(MCPTool.self, from: data)
        }
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard connected else { throw MCPTransportError.notConnected }
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": .object(arguments)
        ])
        let result = try await sendRequest(method: "tools/call", params: params)
        guard case .object(let object) = result,
              case .array(let content) = object["content"] else {
            throw MCPTransportError.invalidResponse
        }
        let isError: Bool
        if case .bool(let value) = object["isError"] {
            isError = value
        } else {
            isError = false
        }
        return MCPToolResult(
            content: content,
            isError: isError,
            structuredContent: object["structuredContent"]
        )
    }

    /// Streams server notifications and the final tool result from an MCP
    /// streamable-HTTP response. Non-SSE JSON responses are surfaced as one
    /// `.result` event.
    public func streamTool(name: String, arguments: [String: JSONValue]) async -> AsyncThrowingStream<MCPStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        guard connected else {
            continuation.finish(throwing: MCPTransportError.notConnected)
            return stream
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let wireRequest = MCPWireRequest(
            jsonrpc: "2.0",
            id: requestID,
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(arguments)
            ])
        )

        do {
            let data = try JSONEncoder().encode(wireRequest)
            let request = makeRequest(data: data)
            let session = self.session
            let timeout = requestTimeout
            let streamID = UUID()
            let owner = self
            let task = Task { [owner] in
                defer {
                    Task { await owner.removeStreamTask(streamID) }
                }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            let (bytes, response) = try await session.bytes(for: request)
                            guard let httpResponse = response as? HTTPURLResponse else {
                                throw MCPTransportError.invalidResponse
                            }
                            guard (200...299).contains(httpResponse.statusCode) else {
                                throw MCPTransportError.httpFailure(httpResponse.statusCode)
                            }
                            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                                await owner.recordSessionID(newSessionID)
                            }

                            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                            if contentType.contains("text/event-stream") {
                                try await Self.consumeSSE(bytes: bytes, continuation: continuation)
                            } else {
                                var body = Data()
                                for try await byte in bytes {
                                    try Task.checkCancellation()
                                    body.append(byte)
                                }
                                guard let event = try Self.decodeStreamEvent(body) else {
                                    throw MCPTransportError.invalidResponse
                                }
                                continuation.yield(event)
                            }
                        }
                        if let timeout, timeout > 0 {
                            group.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw MCPTransportError.timeout(timeout)
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            streamTasks[streamID] = task
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { await self?.removeStreamTask(streamID) }
            }
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }

    public func listResources() async throws -> [MCPResource] {
        guard connected else { throw MCPTransportError.notConnected }
        let result = try await sendRequest(method: "resources/list", params: .object([:]))
        guard case .object(let object) = result,
              case .array(let values) = object["resources"] else {
            throw MCPTransportError.invalidResponse
        }
        return try values.map { value in
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(MCPResource.self, from: data)
        }
    }

    public func readResource(uri: String) async throws -> [MCPResourceContent] {
        guard connected else { throw MCPTransportError.notConnected }
        let result = try await sendRequest(
            method: "resources/read",
            params: .object(["uri": .string(uri)])
        )
        guard case .object(let object) = result,
              case .array(let values) = object["contents"] else {
            throw MCPTransportError.invalidResponse
        }
        return try values.map { value in
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(MCPResourceContent.self, from: data)
        }
    }

    private func sendRequest(method: String, params: JSONValue) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1
        let request = MCPWireRequest(jsonrpc: "2.0", id: requestID, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let responseData = try await send(data: data)
        guard !responseData.isEmpty else { throw MCPTransportError.invalidResponse }
        let response = try decodeResponse(responseData)
        if let error = response.error {
            throw MCPTransportError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw MCPTransportError.invalidResponse }
        return result
    }

    private func sendNotification(method: String) async throws {
        let request = MCPWireNotification(jsonrpc: "2.0", method: method)
        let data = try JSONEncoder().encode(request)
        _ = try await send(data: data)
    }

    private func send(data: Data) async throws -> Data {
        let request = makeRequest(data: data)

        let session = self.session
        let requestForSend = request
        let timeout = requestTimeout
        let (data, response): (Data, URLResponse)
        if let timeout, timeout > 0 {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask {
                    try await session.data(for: requestForSend)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw MCPTransportError.timeout(timeout)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw MCPTransportError.invalidResponse
                }
                return first
            }
        } else {
            (data, response) = try await session.data(for: requestForSend)
        }
        guard let response = response as? HTTPURLResponse else { throw MCPTransportError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            throw MCPTransportError.httpFailure(response.statusCode)
        }
        if let newSessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }
        return data
    }

    private func makeRequest(data: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    private func recordSessionID(_ value: String) {
        sessionID = value
    }

    private func removeStreamTask(_ streamID: UUID) {
        streamTasks[streamID] = nil
    }

    private static func consumeSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<MCPStreamEvent, Error>.Continuation
    ) async throws {
        var line = Data()
        var eventData = Data()

        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    if !eventData.isEmpty {
                        if let event = try decodeStreamEvent(eventData) {
                            continuation.yield(event)
                        }
                        eventData.removeAll(keepingCapacity: true)
                    }
                } else if text.hasPrefix("data:") {
                    let payload = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !payload.isEmpty {
                        if !eventData.isEmpty { eventData.append(10) }
                        eventData.append(contentsOf: Data(payload.utf8))
                    }
                }
                line.removeAll(keepingCapacity: true)
            } else if byte != 13 {
                line.append(byte)
            }
        }

        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("data:") {
                eventData.append(contentsOf: Data(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces).utf8))
            }
        }
        if !eventData.isEmpty, let event = try decodeStreamEvent(eventData) {
            continuation.yield(event)
        }
    }

    private static func decodeStreamEvent(_ data: Data) throws -> MCPStreamEvent? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "[DONE]" else { return nil }
        let message = try JSONDecoder().decode(MCPWireMessage.self, from: Data(text.utf8))
        if let error = message.error {
            throw MCPTransportError.serverError(code: error.code, message: error.message)
        }
        if let result = message.result {
            guard case .object(let object) = result,
                  case .array(let content) = object["content"] else {
                throw MCPTransportError.invalidResponse
            }
            let isError: Bool
            if case .bool(let value) = object["isError"] {
                isError = value
            } else {
                isError = false
            }
            return .result(
                MCPToolResult(
                    content: content,
                    isError: isError,
                    structuredContent: object["structuredContent"]
                )
            )
        }
        if let method = message.method {
            return .notification(method: method, params: message.params)
        }
        throw MCPTransportError.invalidResponse
    }

    private func decodeResponse(_ data: Data) throws -> MCPWireResponse {
        let payload: Data
        if let text = String(data: data, encoding: .utf8) {
            let eventPayloads = text
                .split(whereSeparator: \ .isNewline)
                .compactMap { line -> String? in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    return value.hasPrefix("data:") ? String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces) : nil
                }
                .filter { !$0.isEmpty && $0 != "[DONE]" }
            if let last = eventPayloads.last {
                payload = Data(last.utf8)
            } else {
                payload = data
            }
        } else {
            payload = data
        }
        return try JSONDecoder().decode(MCPWireResponse.self, from: payload)
    }
}

private struct MCPWireRequest: Encodable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: JSONValue
}

private struct MCPWireNotification: Encodable {
    let jsonrpc: String
    let method: String
}

private struct MCPWireResponse: Decodable {
    let result: JSONValue?
    let error: MCPWireError?
}

private struct MCPWireMessage: Decodable {
    let result: JSONValue?
    let error: MCPWireError?
    let method: String?
    let params: JSONValue?
}

private struct MCPWireError: Decodable {
    let code: Int
    let message: String
}

private enum MCPJSONSchemaValidator {
    static func validate(value: JSONValue, schema: JSONValue, path: String) throws {
        guard case let .object(schemaObject) = schema else { return }

        if case let .array(enumValues) = schemaObject["enum"],
           !enumValues.contains(value) {
            throw MCPTransportError.invalidArguments("\(path) is not an allowed value.")
        }

        if case let .string(type) = schemaObject["type"],
           !matches(value: value, type: type) {
            throw MCPTransportError.invalidArguments("\(path) must be \(type).")
        }

        if case let .object(properties) = schemaObject["properties"],
           case let .object(objectValue) = value {
            if case let .array(required) = schemaObject["required"] {
                for item in required {
                    guard case let .string(name) = item,
                          objectValue[name] != nil,
                          objectValue[name] != .null else {
                        throw MCPTransportError.invalidArguments("\(path) is missing required field \(item).")
                    }
                }
            }
            if case .bool(false) = schemaObject["additionalProperties"] {
                let unknown = objectValue.keys.filter { properties[$0] == nil }
                if let first = unknown.sorted().first {
                    throw MCPTransportError.invalidArguments("\(path).\(first) is not permitted.")
                }
            }
            for (name, value) in objectValue {
                if let propertySchema = properties[name] {
                    try validate(value: value, schema: propertySchema, path: "\(path).\(name)")
                }
            }
        }

        if case let .array(items) = value,
           let itemSchema = schemaObject["items"] {
            for (index, item) in items.enumerated() {
                try validate(value: item, schema: itemSchema, path: "\(path)[\(index)]")
            }
        }
    }

    private static func matches(value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string): true
        case ("number", .number): true
        case ("integer", .number(let number)): number.isFinite && number.rounded() == number
        case ("boolean", .bool): true
        case ("object", .object): true
        case ("array", .array): true
        case ("null", .null): true
        default: false
        }
    }
}

public struct AllowReadOnlyMCPPolicy: MCPPermissionPolicy, Sendable {
    public init() {}
    public func allows(_ risk: MCPRisk, tool: MCPTool) async -> Bool { risk == .read }
}

public actor MCPClient {
    private let transport: any MCPTransport
    private let permissionPolicy: any MCPPermissionPolicy
    private var connected = false
    private var toolsByName: [String: MCPTool] = [:]
    private var resourcesByURI: [String: MCPResource] = [:]
    private var promptsByName: [String: MCPPrompt] = [:]
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    public init(transport: any MCPTransport, permissionPolicy: any MCPPermissionPolicy = AllowReadOnlyMCPPolicy()) {
        self.transport = transport
        self.permissionPolicy = permissionPolicy
    }

    public func connect() async throws {
        do {
            try await transport.connect()
            let discoveredTools = try await transport.listTools()
            let discoveredResources: [MCPResource]
            do {
                discoveredResources = try await transport.listResources()
            } catch let error as MCPTransportError where error.isMethodNotFound {
                // Resource support is optional in MCP servers.
                discoveredResources = []
            }
            let discoveredPrompts: [MCPPrompt]
            do {
                discoveredPrompts = try await transport.listPrompts()
            } catch let error as MCPTransportError
                where error.isMethodNotFound || error == .unsupported("prompts/list") {
                // Prompt support is optional in MCP servers and transports.
                discoveredPrompts = []
            }
            toolsByName = Dictionary(discoveredTools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            resourcesByURI = Dictionary(discoveredResources.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
            promptsByName = Dictionary(discoveredPrompts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            connected = true
        } catch {
            await transport.disconnect()
            connected = false
            toolsByName.removeAll()
            resourcesByURI.removeAll()
            promptsByName.removeAll()
            throw error
        }
    }

    public func disconnect() async {
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
        await transport.disconnect()
        connected = false
        toolsByName.removeAll()
        resourcesByURI.removeAll()
        promptsByName.removeAll()
    }

    public func tools() -> [MCPTool] {
        toolsByName.values.sorted { $0.name < $1.name }
    }

    public func resources() -> [MCPResource] {
        resourcesByURI.values.sorted { $0.uri < $1.uri }
    }

    public func prompts() -> [MCPPrompt] {
        promptsByName.values.sorted { $0.name < $1.name }
    }

    public func readResource(uri: String) async throws -> [MCPResourceContent] {
        guard connected, resourcesByURI[uri] != nil else {
            throw ArchonCoreError.invalidConfiguration("MCP client is not connected or resource is unavailable.")
        }
        return try await transport.readResource(uri: uri)
    }

    public func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> MCPPromptResult {
        guard connected, promptsByName[name] != nil else {
            throw ArchonCoreError.invalidConfiguration("MCP client is not connected or prompt is unavailable.")
        }
        return try await transport.getPrompt(name: name, arguments: arguments)
    }

    public func callTool(name: String, arguments: [String: JSONValue] = [:]) async throws -> MCPToolResult {
        guard connected, let tool = toolsByName[name] else {
            throw ArchonCoreError.invalidConfiguration("MCP client is not connected or tool is unavailable.")
        }
        try tool.validate(arguments: arguments)
        guard await permissionPolicy.allows(tool.risk, tool: tool) else {
            throw ArchonCoreError.invalidConfiguration("MCP permission policy denied tool \(name).")
        }
        return try await transport.callTool(name: name, arguments: arguments)
    }

    /// Streams MCP server notifications and the final result while preserving
    /// the same local schema and permission checks as `callTool`.
    public func streamTool(name: String, arguments: [String: JSONValue] = [:]) -> AsyncThrowingStream<MCPStreamEvent, Error> {
        guard connected, let tool = toolsByName[name] else {
            return failedMCPStream(ArchonCoreError.invalidConfiguration("MCP client is not connected or tool is unavailable."))
        }
        let transport = self.transport
        let permissionPolicy = self.permissionPolicy
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        let streamID = UUID()
        let owner = self
        let task = Task { [owner] in
            defer {
                Task { await owner.removeStreamTask(streamID) }
            }
            do {
                try tool.validate(arguments: arguments)
                guard await permissionPolicy.allows(tool.risk, tool: tool) else {
                    throw ArchonCoreError.invalidConfiguration("MCP permission policy denied tool \(name).")
                }
                let remoteStream = await transport.streamTool(name: name, arguments: arguments)
                for try await event in remoteStream {
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        streamTasks[streamID] = task
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { await self?.removeStreamTask(streamID) }
        }
        return stream
    }

    private func removeStreamTask(_ streamID: UUID) {
        streamTasks[streamID] = nil
    }
}

private func failedMCPStream(_ error: Error) -> AsyncThrowingStream<MCPStreamEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
    continuation.finish(throwing: error)
    return stream
}
