import Testing
import ArchonConnect
import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBodies: [Data] = []
    nonisolated(unsafe) static var responseContentTypes: [String] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.delay > 0 { Thread.sleep(forTimeInterval: Self.delay) }
        let body = Self.responseBodies.isEmpty ? Data() : Self.responseBodies.removeFirst()
        let contentType = Self.responseContentTypes.isEmpty
            ? "application/json"
            : Self.responseContentTypes.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: body.isEmpty ? 202 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
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

struct ArchonConnectTests {
    @Test("HTTP MCP transport performs initialize, tool discovery, and tool calls")
    func usesJSONRPCTransport() async throws {
        StubURLProtocol.responseBodies = [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file","description":"Read","inputSchema":{"type":"object"}}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"resources":[{"uri":"file:///README.md","name":"README","mimeType":"text/markdown"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"ok"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":5,"result":{"contents":[{"uri":"file:///README.md","mimeType":"text/markdown","text":"hello"}]}}"#.utf8)
        ]
        defer {
            StubURLProtocol.responseBodies = []
            StubURLProtocol.responseContentTypes = []
            StubURLProtocol.delay = 0
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: URL(string: "https://mcp.example.test")!, session: session)
        let client = MCPClient(transport: transport)

        try await client.connect()
        let result = try await client.callTool(name: "read_file", arguments: ["path": .string("README.md")])
        let contents = try await client.readResource(uri: "file:///README.md")

        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect((await client.tools()).map(\.name) == ["read_file"])
        #expect((await client.resources()).map(\.uri) == ["file:///README.md"])
        #expect(contents.first?.text == "hello")
    }

    @Test("HTTP MCP transport streams server notifications before the final tool result")
    func streamsJSONRPCMessages() async throws {
        StubURLProtocol.responseBodies = [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":0.5}}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}\n\n".utf8)
        ]
        StubURLProtocol.responseContentTypes = [
            "application/json",
            "application/json",
            "text/event-stream"
        ]
        defer {
            StubURLProtocol.responseBodies = []
            StubURLProtocol.responseContentTypes = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: URL(string: "https://mcp.example.test")!, session: session)
        try await transport.connect()

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

    @Test("HTTP MCP transport fails requests that exceed its timeout")
    func enforcesRequestTimeout() async throws {
        StubURLProtocol.responseBodies = [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        ]
        StubURLProtocol.delay = 0.05
        defer {
            StubURLProtocol.responseBodies = []
            StubURLProtocol.delay = 0
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(
            endpoint: URL(string: "https://mcp.example.test")!,
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
}
