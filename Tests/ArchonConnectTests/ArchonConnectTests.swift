import Testing
import ArchonConnect
import Foundation

private struct StubResponseState: Sendable {
    var responseBodies: [Data]
    var responseContentTypes: [String]
    var delay: TimeInterval
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var statesByEndpoint: [String: StubResponseState] = [:]

    private static func key(for url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }

    static func configure(
        responseBodies: [Data],
        responseContentTypes: [String] = [],
        delay: TimeInterval = 0,
        for endpoint: URL
    ) {
        stateLock.lock()
        statesByEndpoint[key(for: endpoint)] = StubResponseState(
            responseBodies: responseBodies,
            responseContentTypes: responseContentTypes,
            delay: delay
        )
        stateLock.unlock()
    }

    static func setDelay(_ delay: TimeInterval, for endpoint: URL) {
        stateLock.lock()
        statesByEndpoint[key(for: endpoint)]?.delay = delay
        stateLock.unlock()
    }

    static func reset(for endpoint: URL) {
        stateLock.lock()
        statesByEndpoint.removeValue(forKey: key(for: endpoint))
        stateLock.unlock()
    }

    private static func nextResponse(for request: URLRequest) -> (body: Data, contentType: String, delay: TimeInterval) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let endpointKey = key(for: request.url)
        guard var state = statesByEndpoint[endpointKey] else {
            return (Data(), "application/json", 0)
        }
        var body = state.responseBodies.isEmpty ? Data() : state.responseBodies.removeFirst()
        let contentType = state.responseContentTypes.isEmpty
            ? "application/json"
            : state.responseContentTypes.removeFirst()
        statesByEndpoint[endpointKey] = state
        var text = String(decoding: body, as: UTF8.self)
        let metadata = requestMetadata(in: request)
        if let requestID = metadata.id {
            text = text.replacingOccurrences(of: "__REQUEST_ID__", with: requestID)
        }
        if let progressToken = metadata.progressToken {
            text = text.replacingOccurrences(of: "__PROGRESS_TOKEN__", with: progressToken)
        }
        body = Data(text.utf8)
        return (body, contentType, state.delay)
    }

    private static func requestMetadata(in request: URLRequest) -> (id: String?, progressToken: String?) {
        guard
            let body = requestBody(for: request),
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let id = root["id"]
        else {
            return (nil, nil)
        }
        let progressToken: String?
        if let params = root["params"] as? [String: Any],
           let metadata = params["_meta"] as? [String: Any],
           let token = metadata["progressToken"] {
            progressToken = String(describing: token)
        } else {
            progressToken = nil
        }
        return (String(describing: id), progressToken)
    }

    private static func requestBody(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, contentType, delay) = Self.nextResponse(for: request)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: body.isEmpty ? 202 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor MockTransport: MCPTransport {
    var connected = false
    let availableTools: [MCPTool]

    init(availableTools: [MCPTool]) { self.availableTools = availableTools }

    func connect() async throws { connected = true }
    func disconnect() async { connected = false }
    func listTools() async throws -> [MCPTool] { availableTools }
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        MCPToolResult(content: [.string(name)])
    }
}

private struct HostApprovedReadOnlyPolicy: MCPPermissionPolicy, Sendable {
    func allows(_ risk: MCPRisk, tool: MCPTool) async -> Bool {
        risk == .read
    }
}

private actor CancellableMockTransport: MCPTransport {
    private var streamContinuation: AsyncThrowingStream<MCPStreamEvent, Error>.Continuation?
    private var streamWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationObserved = false

    func connect() async throws {}
    func disconnect() async {}
    func listTools() async throws -> [MCPTool] { [MCPTool(name: "stream")] }
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        MCPToolResult(content: [.string(name)])
    }

    func streamTool(name: String, arguments: [String: JSONValue]) async -> AsyncThrowingStream<MCPStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        streamContinuation = continuation
        for waiter in streamWaiters { waiter.resume() }
        streamWaiters.removeAll()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.markTermination() }
        }
        return stream
    }

    func waitForStream() async {
        if streamContinuation != nil { return }
        await withCheckedContinuation { streamWaiters.append($0) }
    }

    func didObserveTermination() -> Bool { terminationObserved }

    private func markTermination() {
        terminationObserved = true
    }
}

private struct TestTimeout: Error {}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestTimeout()
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw TestTimeout()
        }
        return value
    }
}

struct ArchonConnectTests {
    @Test("HTTP MCP transport performs initialize, tool discovery, and tool calls")
    func usesJSONRPCTransport() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file","description":"Read","inputSchema":{"type":"object"}}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"resources":[{"uri":"file:///README.md","name":"README","mimeType":"text/markdown"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"ok"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":5,"result":{"contents":[{"uri":"file:///README.md","mimeType":"text/markdown","text":"hello"}]}}"#.utf8)
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)
        let client = MCPClient(
            transport: transport,
            permissionPolicy: HostApprovedReadOnlyPolicy()
        )

        try await client.connect()
        let result = try await client.callTool(name: "read_file", arguments: ["path": .string("README.md")])
        let contents = try await client.readResource(uri: "file:///README.md")

        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect((await client.tools()).map(\.name) == ["read_file"])
        #expect((await client.resources()).map(\.uri) == ["file:///README.md"])
        #expect(contents.first?.text == "hello")
    }

    @Test("HTTP MCP JSON responses containing data text are not mistaken for SSE")
    func preservesJSONResponseContainingDataText() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"metadata: data: chunk"}]}}"#.utf8)
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)

        try await transport.connect()
        await transport.setAuthorizedToolNames(["metadata"])
        let result = try await transport.callTool(name: "metadata", arguments: [:])

        guard case .object(let value) = result.content.first,
              case .string(let text) = value["text"] else {
            Issue.record("Expected a text content item.")
            return
        }
        #expect(text == "metadata: data: chunk")
    }

    @Test("HTTP MCP transport streams server notifications before the final tool result")
    func streamsJSONRPCMessages() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":0.5}}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}\n\n".utf8)
        ], responseContentTypes: [
            "application/json",
            "application/json",
            "text/event-stream"
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)
        try await transport.connect()
        await transport.setAuthorizedToolNames(["progress_tool"])

        let events = await transport.streamTool(name: "progress_tool", arguments: [:])
        var sawProgress = false
        var resultText: String?
        for try await event in events {
            switch event {
            case .notification(let method, _):
                sawProgress = method == "notifications/progress"
            case .result(let result):
                if case .object(let value) = result.content.first,
                   case .string(let text) = value["text"] {
                    resultText = text
                }
            }
        }

        #expect(sawProgress)
        #expect(resultText == "done")
    }

    @Test("Disconnecting the HTTP transport cancels an active stream")
    func disconnectsHTTPTransportStream() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"late"}]}}"#.utf8)
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)
        try await transport.connect()
        await transport.setAuthorizedToolNames(["slow_tool"])

        StubURLProtocol.setDelay(0.05, for: endpoint)
        let events = await transport.streamTool(name: "slow_tool", arguments: [:])
        await transport.disconnect()

        var receivedEvents: [MCPStreamEvent] = []
        do {
            for try await event in events { receivedEvents.append(event) }
        } catch is CancellationError {
            // Disconnect is expected to cancel the active URLSession stream.
        }
        #expect(receivedEvents.isEmpty)
    }

    @Test("Cancelling an MCP stream consumer terminates the underlying transport stream")
    func cancelsStreamConsumer() async throws {
        let transport = CancellableMockTransport()
        let client = MCPClient(transport: transport)
        try await client.connect()

        let stream = await client.streamTool(name: "stream")
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is asserted through the transport below.
            }
        }

        await transport.waitForStream()
        consumer.cancel()
        _ = await consumer.result
        try await Task.sleep(for: .milliseconds(20))

        #expect(await transport.didObserveTermination())
    }

    @Test("Disconnecting an MCP client terminates active streams")
    func disconnectsActiveStream() async throws {
        let transport = CancellableMockTransport()
        let client = MCPClient(transport: transport)
        try await client.connect()

        let stream = await client.streamTool(name: "stream")
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Disconnect is asserted through the transport below.
            }
        }

        await transport.waitForStream()
        await client.disconnect()
        _ = await consumer.result
        try await Task.sleep(for: .milliseconds(20))

        #expect(await transport.didObserveTermination())
    }

    @Test("Official MCP SDK adapter fails closed before connection")
    func officialSDKAdapterRequiresConnection() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            streaming: false
        )

        do {
            _ = try await transport.listTools()
            Issue.record("Expected the official MCP adapter to require connection.")
        } catch let error as MCPTransportError {
            #expect(error == .notConnected)
        }
    }

    @Test("Official MCP SDK adapter does not mutate caller session configuration")
    func officialSDKAdapterCopiesSessionConfiguration() {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 37

        _ = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            requestTimeout: 1
        )

        #expect(configuration.timeoutIntervalForRequest == 37)
    }

    @Test("Official MCP SDK adapter maps paginated tools, resources, and structured output")
    func officialSDKAdapterMapsStandardSemantics() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"resources":{}},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"tools":[{"name":"read_file","title":"Read file","description":"Read","inputSchema":{"type":"object"},"outputSchema":{"type":"object","properties":{"answer":{"type":"string"}}},"annotations":{"readOnlyHint":true}}],"nextCursor":"tools-page-2"}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"tools":[{"name":"delete_file","description":"Delete","inputSchema":{"type":"object"},"annotations":{"destructiveHint":true}}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"resources":[{"uri":"file:///README.md","name":"README","mimeType":"text/markdown"}],"nextCursor":"resources-page-2"}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"resources":[{"uri":"file:///LICENSE","name":"LICENSE","mimeType":"text/plain"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"content":[{"type":"text","text":"ok"}],"structuredContent":{"answer":"ok"}}}"#.utf8)
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 0.5
        )

        let (tools, resources, result) = try await withTimeout(.seconds(2)) {
            try await transport.connect()
            let tools = try await transport.listTools()
            let resources = try await transport.listResources()
            await transport.setAuthorizedToolNames(["read_file"])
            let result = try await transport.callTool(name: "read_file", arguments: [:])
            return (tools, resources, result)
        }

        #expect(tools.map(\.name) == ["read_file", "delete_file"])
        #expect(tools.first?.title == "Read file")
        #expect(tools.first?.outputSchema?["type"] == .string("object"))
        #expect(tools.last?.risk == .destructive)
        #expect(resources.map(\.uri) == ["file:///README.md", "file:///LICENSE"])
        #expect(result.structuredContent == .object(["answer": .string("ok")]))
    }

    @Test("Official MCP SDK adapter surfaces progress notifications through Archon events")
    func officialSDKAdapterStreamsProgress() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8),
            Data(),
            Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"__PROGRESS_TOKEN__\",\"progress\":0.5,\"total\":1,\"message\":\"halfway\"}}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"__REQUEST_ID__\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}\n\n".utf8)
        ], responseContentTypes: [
            "application/json",
            "application/json",
            "text/event-stream"
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 0.5
        )

        let (sawProgress, resultText) = try await withTimeout(.seconds(2)) {
            try await transport.connect()
            await transport.setAuthorizedToolNames(["long_task"])
            let events = await transport.streamTool(name: "long_task", arguments: [:])
            var sawProgress = false
            var resultText: String?
            for try await event in events {
                switch event {
                case .notification(let method, let params):
                    guard method == "notifications/progress",
                          case .object(let params) = params,
                          params["progress"] == .number(0.5),
                          params["message"] == .string("halfway") else { continue }
                    sawProgress = true
                case .result(let result):
                    if case .object(let value) = result.content.first,
                       case .string(let text) = value["text"] {
                        resultText = text
                    }
                }
            }
            return (sawProgress, resultText)
        }

        #expect(sawProgress)
        #expect(resultText == "done")
    }

    @Test("Official MCP SDK adapter maps paginated prompts and prompt messages")
    func officialSDKAdapterMapsPrompts() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"protocolVersion":"2025-11-25","capabilities":{"prompts":{}},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"prompts":[{"name":"summarize","title":"Summarize","description":"Summarize text","arguments":[{"name":"text","required":true}]}],"nextCursor":"prompts-page-2"}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"prompts":[{"name":"plan","description":"Plan work"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"description":"A summary prompt","messages":[{"role":"user","content":{"type":"text","text":"Summarize {{text}}"}}]}}"#.utf8)
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 0.5
        )

        let (prompts, result) = try await withTimeout(.seconds(2)) {
            try await transport.connect()
            let prompts = try await transport.listPrompts()
            let result = try await transport.getPrompt(name: "summarize", arguments: ["text": "hello"])
            return (prompts, result)
        }

        #expect(prompts.map(\.name) == ["summarize", "plan"])
        #expect(prompts.first?.arguments.first?.required == true)
        #expect(result.description == "A summary prompt")
        #expect(result.messages.first?.role == "user")
        #expect(result.messages.first?.content == .object([
            "type": .string("text"),
            "text": .string("Summarize {{text}}")
        ]))
    }

    @Test("HTTP MCP transport fails requests that exceed its timeout")
    func enforcesRequestTimeout() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        StubURLProtocol.configure(
            responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
            ],
            delay: 0.05,
            for: endpoint
        )
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(
            endpoint: endpoint,
            session: session,
            requestTimeout: 0.001
        )

        do {
            try await transport.connect()
            Issue.record("Expected MCP initialize to time out.")
        } catch let error as MCPTransportError {
            guard case .timeout = error else {
                Issue.record("Expected a timeout, received \(error).")
                return
            }
        }
    }

    @Test("MCP wire tool metadata defaults local risk and ID fields")
    func decodesStandardToolShape() throws {
        let data = Data(#"{"name":"read_file","description":"Read a file","inputSchema":{"type":"object"}}"#.utf8)
        let tool = try JSONDecoder().decode(MCPTool.self, from: data)

        #expect(tool.name == "read_file")
        #expect(tool.id == "read_file")
        #expect(tool.risk == .read)
        #expect(tool.trust == .remoteUnverified)
    }

    @Test("MCP wire resource metadata defaults its local identity")
    func decodesStandardResourceShape() throws {
        let data = Data(#"{"uri":"file:///README.md","name":"README","mimeType":"text/markdown"}"#.utf8)
        let resource = try JSONDecoder().decode(MCPResource.self, from: data)

        #expect(resource.id == "file:///README.md")
        #expect(resource.name == "README")
        #expect(resource.mimeType == "text/markdown")
    }

    @Test("MCP tool schemas reject missing and wrongly typed arguments locally")
    func validatesToolArguments() throws {
        let tool = MCPTool(
            name: "read_file",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path")])
            ]
        )

        try tool.validate(arguments: ["path": .string("README.md")])

        do {
            try tool.validate(arguments: ["path": .number(42)])
            Issue.record("Expected invalid MCP arguments to be rejected.")
        } catch let error as MCPTransportError {
            guard case .invalidArguments = error else {
                Issue.record("Expected invalidArguments, received \(error).")
                return
            }
        }
    }

    @Test("MCP client exposes tools after connection")
    func connectsAndListsTools() async throws {
        let transport = MockTransport(availableTools: [MCPTool(name: "read_file")])
        let client = MCPClient(transport: transport)

        try await client.connect()
        let tools = await client.tools()

        #expect(tools.map(\.name) == ["read_file"])
    }

    @Test("Read-only MCP policy denies mutating tools")
    func deniesMutatingTool() async throws {
        let transport = MockTransport(availableTools: [MCPTool(name: "delete_file", risk: .destructive)])
        let client = MCPClient(transport: transport)
        try await client.connect()

        do {
            _ = try await client.callTool(name: "delete_file")
            Issue.record("Expected the read-only policy to deny a destructive tool.")
        } catch {
            #expect(error.localizedDescription.contains("denied"))
        }
    }

    @Test("Read-only MCP policy rejects remote risk metadata without host approval")
    func deniesRemoteRiskMetadata() async throws {
        let transport = MockTransport(availableTools: [
            MCPTool(name: "remote_read", risk: .read, trust: .remoteUnverified)
        ])
        let client = MCPClient(transport: transport)

        try await client.connect()
        do {
            _ = try await client.callTool(name: "remote_read")
            Issue.record("Expected remote MCP metadata to remain unapproved.")
        } catch {
            #expect(error.localizedDescription.contains("denied"))
        }
    }

    @Test("HTTP MCP transport bounds complete response bodies")
    func boundsHTTPResponseBody() async throws {
        let endpoint = URL(string: "https://mcp.example.test/rpc-\(UUID().uuidString)")!
        let oversizedBody = Data(repeating: 0x61, count: 8 * 1024 * 1024 + 1)
        StubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            oversizedBody
        ], for: endpoint)
        defer { StubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)
        try await transport.connect()
        await transport.setAuthorizedToolNames(["oversized"])

        do {
            _ = try await transport.callTool(name: "oversized", arguments: [:])
            Issue.record("Expected the oversized MCP response to be rejected.")
        } catch let error as MCPTransportError {
            #expect(error == .responseTooLarge(maximumBytes: 8 * 1024 * 1024))
        }
    }
}
