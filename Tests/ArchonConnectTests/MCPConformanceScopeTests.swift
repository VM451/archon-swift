import Testing
@testable import ArchonConnect
import Foundation
import MCP

private struct ConformanceStubState: Sendable {
    var responseBodies: [Data]
    var responseContentTypes: [String]
    var delay: TimeInterval
}

private final class ConformanceStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var statesByEndpoint: [String: ConformanceStubState] = [:]

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
        statesByEndpoint[key(for: endpoint)] = ConformanceStubState(
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
        if let requestID = requestID(in: request) {
            text = text.replacingOccurrences(of: "__REQUEST_ID__", with: requestID)
        }
        body = Data(text.utf8)
        return (body, contentType, state.delay)
    }

    private static func requestID(in request: URLRequest) -> String? {
        guard
            let body = requestBody(for: request),
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let id = root["id"]
        else { return nil }
        return String(describing: id)
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

struct MCPConformanceScopeTests {
    private func officialTransport(
        bodies: [Data],
        endpoint: URL,
        contentTypes: [String] = []
    ) -> OfficialMCPTransport {
        ConformanceStubURLProtocol.configure(
            responseBodies: bodies,
            responseContentTypes: contentTypes,
            for: endpoint
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConformanceStubURLProtocol.self]
        return OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 2
        )
    }

    private func initializeBodies() -> [Data] {
        [
            Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#.utf8),
            Data()
        ]
    }

    @Test("Tools pagination cursor cycles fail with invalidResponse")
    func toolsCursorCycleRejected() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-tools-\(UUID().uuidString)")!
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }
        let page = Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"tools":[{"name":"a","inputSchema":{"type":"object"}}],"nextCursor":"loop"}}"#.utf8)
        let transport = officialTransport(
            bodies: initializeBodies() + [page, page],
            endpoint: endpoint
        )
        try await transport.connect()
        do {
            _ = try await transport.listTools()
            Issue.record("Expected a cycling tools cursor to be rejected.")
        } catch let error as MCPTransportError {
            #expect(error == .invalidResponse)
        }
        await transport.disconnect()
    }

    @Test("Resources pagination cursor cycles fail uniformly")
    func resourcesCursorCycleRejected() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-resources-\(UUID().uuidString)")!
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }
        let page = Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"resources":[{"uri":"file:///a.md","name":"a"}],"nextCursor":"loop"}}"#.utf8)
        let transport = officialTransport(
            bodies: initializeBodies() + [page, page],
            endpoint: endpoint
        )
        try await transport.connect()
        do {
            _ = try await transport.listResources()
            Issue.record("Expected a cycling resources cursor to be rejected.")
        } catch let error as MCPTransportError {
            #expect(error == .invalidResponse)
        }
        await transport.disconnect()
    }

    @Test("Prompts pagination cursor cycles fail uniformly")
    func promptsCursorCycleRejected() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-prompts-\(UUID().uuidString)")!
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }
        let page = Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"prompts":[{"name":"p"}],"nextCursor":"loop"}}"#.utf8)
        let transport = officialTransport(
            bodies: initializeBodies() + [page, page],
            endpoint: endpoint
        )
        try await transport.connect()
        do {
            _ = try await transport.listPrompts()
            Issue.record("Expected a cycling prompts cursor to be rejected.")
        } catch let error as MCPTransportError {
            #expect(error == .invalidResponse)
        }
        await transport.disconnect()
    }

    @Test("Collections over 1000 items fail with collectionTooLarge")
    func oversizedCollectionRejected() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-bound-\(UUID().uuidString)")!
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }
        let entries = (0..<1_001)
            .map { #"{"name":"tool-\#($0)","inputSchema":{"type":"object"}}"# }
            .joined(separator: ",")
        let page = Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"tools":[\#(entries)]}}"#.utf8)
        let transport = officialTransport(
            bodies: initializeBodies() + [page],
            endpoint: endpoint
        )
        try await transport.connect()
        do {
            _ = try await transport.listTools()
            Issue.record("Expected the 1001-item collection to be rejected.")
        } catch let error as MCPTransportError {
            #expect(error == .collectionTooLarge(maximumItems: 1_000))
        }
        await transport.disconnect()
    }

    @Test("Fake-driven conformance probe reports cycles, bounds, and notifications")
    func conformanceProbeReport() async {
        let report = await conformanceProbe()
        #expect(report == MCPConformanceReport(
            paginationCursorsCycled: true,
            collectionBoundHits: 1,
            notificationsForwarded: ["notifications/progress", "notifications/tools/list_changed"]
        ))
    }

    @Test("Bounded disconnect cancels in-flight streams and clears tool grants")
    func boundedDisconnectCancelsAndClears() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-teardown-\(UUID().uuidString)")!
        ConformanceStubURLProtocol.configure(responseBodies: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data(),
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"late"}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":4,"result":{"protocolVersion":"2025-06-18"}}"#.utf8),
            Data()
        ], for: endpoint)
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConformanceStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = MCPHTTPTransport(endpoint: endpoint, session: session)
        try await transport.connect()
        await transport.setAuthorizedToolNames(["slow_tool"])

        ConformanceStubURLProtocol.setDelay(0.05, for: endpoint)
        let events = await transport.streamTool(name: "slow_tool", arguments: [:])
        await transport.disconnect(timeout: 5)

        var received: [MCPStreamEvent] = []
        do {
            for try await event in events { received.append(event) }
        } catch is CancellationError {
            // Bounded disconnect is expected to cancel the active stream.
        }
        #expect(received.isEmpty)

        // Grants do not survive disconnect: reconnecting without re-authorizing
        // must refuse the tool call.
        try await transport.connect()
        do {
            _ = try await transport.callTool(name: "slow_tool", arguments: [:])
            Issue.record("Expected tool grants to be cleared by disconnect.")
        } catch {
            #expect(error.localizedDescription.contains("has not been approved"))
        }
        await transport.disconnect()
    }

    @Test("Unset hosted capabilities stay unhandled on a bare connection")
    func unsetHostedCapabilitiesNotAdvertised() async throws {
        let endpoint = URL(string: "https://mcp.example.test/conform-bare-\(UUID().uuidString)")!
        defer { ConformanceStubURLProtocol.reset(for: endpoint) }
        let transport = officialTransport(
            bodies: initializeBodies() + [
                Data(#"{"jsonrpc":"2.0","id":"__REQUEST_ID__","result":{"tools":[]}}"#.utf8)
            ],
            endpoint: endpoint
        )
        try await transport.connect()
        #expect(try await transport.listTools().isEmpty)
        // Unset hosted capabilities are never advertised and fail closed when
        // a server-initiated request arrives.
        do {
            _ = try await transport.handleListRoots()
            Issue.record("Expected unset roots handling to fail closed.")
        } catch let error as MCPTransportError {
            #expect(error == .unsupported("roots/list"))
        }
        await transport.disconnect()
    }
}
