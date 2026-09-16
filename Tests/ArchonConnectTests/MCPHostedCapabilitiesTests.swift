import Testing
import Foundation
import MCP
@testable import ArchonConnect

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodiesByEndpoint: [String: [Data]] = [:]

    static func bodies(for endpoint: URL) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodiesByEndpoint[key(for: endpoint)] ?? []
    }

    static func reset(for endpoint: URL) {
        lock.lock()
        bodiesByEndpoint.removeValue(forKey: key(for: endpoint))
        lock.unlock()
    }

    private static func key(for url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }

    private static func record(_ body: Data?, for url: URL?) {
        lock.lock()
        bodiesByEndpoint[key(for: url), default: []].append(body ?? Data())
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.requestBody(for: request) ?? Data()
        Self.record(body, for: request.url)
        // Foundation escapes "/" as "\/" in JSON bodies; normalize so method
        // matching works for both hand-rolled and SDK encoders.
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        let payload: Data
        let status: Int
        if text.contains("\"initialize\"") {
            let id = Self.requestID(in: body) ?? "1"
            payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8)
            status = 200
        } else if text.contains("tools/list") {
            let id = Self.requestID(in: body) ?? "2"
            payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[]}}"#.utf8)
            status = 200
        } else if text.contains("resources/list") || text.contains("prompts/list") {
            let id = Self.requestID(in: body) ?? "3"
            payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
            status = 200
        } else {
            payload = Data()
            status = 202
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

    private static func requestID(in body: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let id = root["id"]
        else { return nil }
        if let string = id as? String { return "\"\(string)\"" }
        return String(describing: id)
    }
}

struct MCPHostedCapabilitiesTests {
    @Test("Hosted capabilities default to empty and inert")
    func defaultsToEmpty() {
        let empty = MCPHostedCapabilities()
        #expect(empty.isEmpty)
        #expect(empty.roots == nil && empty.sampling == nil && empty.elicitation == nil)

        let withRoots = MCPHostedCapabilities(roots: { [] })
        #expect(!withRoots.isEmpty)
    }

    @Test("Roots handler serves host roots with names preserved")
    func rootsHandlerServesHostRoots() async throws {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/roots")!,
            streaming: false
        )
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            roots: {
                [MCPHostRoot(uri: "file:///workspace", name: "Workspace"),
                 MCPHostRoot(uri: "file:///notes")]
            }
        ))

        let result = try await transport.handleListRoots()
        #expect(result.roots.map(\.uri) == ["file:///workspace", "file:///notes"])
        #expect(result.roots.map(\.name) == ["Workspace", nil])
    }

    @Test("Missing roots handler fails closed with unsupported")
    func missingRootsHandlerFailsClosed() async {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/roots-missing")!,
            streaming: false
        )
        await expectUnsupported("roots/list") {
            try await transport.handleListRoots()
        }
    }

    @Test("Roots handler enforces the shared collection bound")
    func rootsCollectionBoundEnforced() async {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/roots-bound")!,
            streaming: false
        )
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            roots: { (0..<1_001).map { MCPHostRoot(uri: "file:///root-\($0)") } }
        ))
        do {
            _ = try await transport.handleListRoots()
            Issue.record("Expected the roots collection bound to throw.")
        } catch let error as MCPTransportError {
            #expect(error == .collectionTooLarge(maximumItems: 1_000))
        } catch {
            Issue.record("Unexpected error: \(error).")
        }
    }

    @Test("Sampling handler maps the full request and returns a text completion")
    func samplingRoundTrip() async throws {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/sampling")!,
            streaming: false
        )
        let captured = LockedBox<MCPSamplingRequest>()
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            sampling: { request in
                captured.store(request)
                return MCPSamplingResponse(model: "host-model", text: "done", stopReason: "custom-reason")
            }
        ))

        let params = MCP.CreateSamplingMessage.Parameters(
            messages: [
                MCP.Sampling.Message(role: .user, content: .single(.text("Summarize this."))),
                MCP.Sampling.Message(
                    role: .assistant,
                    content: .multiple([
                        .image(data: "aW1hZ2U=", mimeType: "image/png"),
                        .toolUse(MCP.Sampling.ToolUseContent(
                            id: "call-1",
                            name: "read_file",
                            input: ["path": .string("README.md"), "count": .int(3)]
                        )),
                        .toolResult(MCP.Sampling.ToolResultContent(
                            toolUseId: "call-1",
                            content: [
                                .text("file contents"),
                                .resourceLink(
                                    uri: "file:///README.md",
                                    name: "README",
                                    title: nil,
                                    description: nil,
                                    mimeType: "text/markdown",
                                    annotations: nil
                                )
                            ],
                            structuredContent: ["lines": .int(42)],
                            isError: true
                        ))
                    ])
                )
            ],
            modelPreferences: MCP.Sampling.ModelPreferences(hints: [.init(name: "fast"), .init()]),
            systemPrompt: "Be concise.",
            includeContext: .thisServer,
            temperature: 0.2,
            maxTokens: 128,
            stopSequences: ["###"]
        )
        let result = try await transport.handleSampling(params)

        let request = try #require(captured.load())
        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == .user)
        #expect(request.messages[0].content == [.text("Summarize this.")])
        #expect(request.messages[1].role == .assistant)
        #expect(request.messages[1].content.count == 3)
        #expect(request.messages[1].content[0] == .image(data: "aW1hZ2U=", mimeType: "image/png"))
        #expect(request.messages[1].content[1] == .toolUse(
            id: "call-1",
            name: "read_file",
            input: ["path": .string("README.md"), "count": .number(3)]
        ))
        #expect(request.messages[1].content[2] == .toolResult(
            toolUseId: "call-1",
            blocks: [
                .text("file contents"),
                .resourceLink(uri: "file:///README.md", name: "README", mimeType: "text/markdown")
            ],
            structured: ["lines": .number(42)],
            isError: true
        ))
        #expect(request.systemPrompt == "Be concise.")
        #expect(request.maxTokens == 128)
        #expect(request.temperature == 0.2)
        #expect(request.stopSequences == ["###"])
        #expect(request.modelHints == ["fast"])
        #expect(request.includeContext == "thisServer")

        #expect(result.model == "host-model")
        #expect(result.role == .assistant)
        #expect(result.stopReason?.rawValue == "custom-reason")
        guard case .single(.text(let text)) = result.content else {
            Issue.record("Expected a single text completion, got \(result.content).")
            return
        }
        #expect(text == "done")
    }

    @Test("Missing sampling handler fails closed with unsupported")
    func missingSamplingHandlerFailsClosed() async {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/sampling-missing")!,
            streaming: false
        )
        let params = MCP.CreateSamplingMessage.Parameters(
            messages: [MCP.Sampling.Message(role: .user, content: .single(.text("hi")))],
            maxTokens: 8
        )
        await expectUnsupported("sampling/createMessage") {
            try await transport.handleSampling(params)
        }
    }

    @Test("Form elicitation maps schema and submits accepted content")
    func formElicitationRoundTrip() async throws {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/elicit-form")!,
            streaming: false
        )
        let captured = LockedBox<MCPElicitationRequest>()
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            elicitation: { request in
                captured.store(request)
                return MCPElicitationResponse(
                    action: .accept,
                    content: ["nickname": .string("ada"), "retries": .number(2)]
                )
            }
        ))

        let params = MCP.CreateElicitation.Parameters.form(
            MCP.CreateElicitation.Parameters.FormParameters(
                message: "Pick a nickname.",
                mode: .form,
                requestedSchema: MCP.Elicitation.RequestSchema(
                    properties: ["nickname": .object(["type": .string("string")])],
                    required: ["nickname"]
                )
            )
        )
        let result = try await transport.handleElicitation(params)

        let request = try #require(captured.load())
        #expect(request.message == "Pick a nickname.")
        #expect(request.mode == "form")
        #expect(request.kind == .form(
            properties: ["nickname": .object(["type": .string("string")])],
            required: ["nickname"]
        ))
        #expect(result.action == .accept)
        #expect(result.content == ["nickname": .string("ada"), "retries": .double(2)])
    }

    @Test("Declined elicitation drops submitted content")
    func declinedElicitationDropsContent() async throws {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/elicit-decline")!,
            streaming: false
        )
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            elicitation: { _ in MCPElicitationResponse(action: .decline, content: ["x": .bool(true)]) }
        ))
        let params = MCP.CreateElicitation.Parameters.form(
            MCP.CreateElicitation.Parameters.FormParameters(
                message: "Optional.",
                requestedSchema: MCP.Elicitation.RequestSchema(properties: [:])
            )
        )
        let result = try await transport.handleElicitation(params)
        #expect(result.action == .decline)
        #expect(result.content == nil)
    }

    @Test("URL elicitation maps the out-of-band review link")
    func urlElicitationRoundTrip() async throws {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/elicit-url")!,
            streaming: false
        )
        let captured = LockedBox<MCPElicitationRequest>()
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            elicitation: { request in
                captured.store(request)
                return MCPElicitationResponse(action: .cancel)
            }
        ))
        let params = MCP.CreateElicitation.Parameters.url(
            MCP.CreateElicitation.Parameters.URLParameters(
                message: "Review in browser.",
                url: "https://review.example.test/e/1",
                elicitationId: "e-1"
            )
        )
        let result = try await transport.handleElicitation(params)

        let request = try #require(captured.load())
        #expect(request.mode == "url")
        #expect(request.kind == .url(url: "https://review.example.test/e/1", elicitationId: "e-1"))
        #expect(result.action == .cancel)
        #expect(result.content == nil)
    }

    @Test("Missing elicitation handler fails closed with unsupported")
    func missingElicitationHandlerFailsClosed() async {
        let transport = OfficialMCPTransport(
            endpoint: URL(string: "https://mcp.example.test/elicit-missing")!,
            streaming: false
        )
        let params = MCP.CreateElicitation.Parameters.url(
            MCP.CreateElicitation.Parameters.URLParameters(
                message: "Review.",
                url: "https://review.example.test/e/2",
                elicitationId: "e-2"
            )
        )
        await expectUnsupported("elicitation/create") {
            try await transport.handleElicitation(params)
        }
    }

    @Test("Initialize advertises exactly the installed hosted capabilities")
    func initializeAdvertisesHostedCapabilities() async throws {
        let endpoint = URL(string: "https://mcp.example.test/caps-\(UUID().uuidString)")!
        CaptureURLProtocol.reset(for: endpoint)
        defer { CaptureURLProtocol.reset(for: endpoint) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false
        )
        await transport.setHostedCapabilities(MCPHostedCapabilities(
            roots: { [] },
            sampling: { _ in MCPSamplingResponse(model: "m", text: "t") },
            elicitation: { _ in MCPElicitationResponse(action: .cancel) }
        ))

        try await transport.connect()
        await transport.disconnect()

        let bodies = CaptureURLProtocol.bodies(for: endpoint)
        let initialize = try #require(bodies.first { String(decoding: $0, as: UTF8.self).contains("\"initialize\"") })
        let root = try #require(try JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        let params = try #require(root["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["sampling"] != nil)
        #expect(capabilities["elicitation"] != nil)
        #expect(capabilities["roots"] != nil)
    }

    @Test("Initialize without hosted capabilities stays unadvertised")
    func initializeWithoutCapabilitiesStaysBare() async throws {
        let endpoint = URL(string: "https://mcp.example.test/bare-\(UUID().uuidString)")!
        CaptureURLProtocol.reset(for: endpoint)
        defer { CaptureURLProtocol.reset(for: endpoint) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false
        )

        try await transport.connect()
        await transport.disconnect()

        let bodies = CaptureURLProtocol.bodies(for: endpoint)
        let initialize = try #require(bodies.first { String(decoding: $0, as: UTF8.self).contains("\"initialize\"") })
        let root = try #require(try JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        let params = try #require(root["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["sampling"] == nil)
        #expect(capabilities["elicitation"] == nil)
        #expect(capabilities["roots"] == nil)
    }

    @Test("Native transport ignores hosted capabilities and still connects")
    func nativeTransportIgnoresHostedCapabilities() async throws {
        let endpoint = URL(string: "https://mcp.example.test/native-\(UUID().uuidString)")!
        CaptureURLProtocol.reset(for: endpoint)
        defer { CaptureURLProtocol.reset(for: endpoint) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = MCPClient(transport: MCPHTTPTransport(endpoint: endpoint, session: session))
        await client.setHostedCapabilities(MCPHostedCapabilities(
            roots: { [MCPHostRoot(uri: "file:///workspace")] }
        ))

        try await client.connect()
        #expect(await client.tools().isEmpty)
        await client.disconnect()
    }

    private func expectUnsupported(
        _ operation: String,
        _ action: () async throws -> some Any
    ) async {
        do {
            _ = try await action()
            Issue.record("Expected \(operation) to throw unsupported.")
        } catch let error as MCPTransportError {
            #expect(error == .unsupported(operation))
        } catch {
            Issue.record("Unexpected error: \(error).")
        }
    }
}
