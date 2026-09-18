import Testing
import ArchonConnect
import Foundation

private actor TeardownFakeTransport: MCPTransport {
    private var streamContinuation: AsyncThrowingStream<MCPStreamEvent, Error>.Continuation?
    private var streamWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationObserved = false
    private(set) var disconnectCalls = 0

    func connect() async throws {}
    func disconnect() async { disconnectCalls += 1 }
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

private struct TeardownAllowAll: MCPPermissionPolicy, Sendable {
    func allows(_ risk: MCPRisk, tool: MCPTool) async -> Bool { true }
}

struct MCPTransportTeardownTests {
    @Test("Double disconnect is idempotent across transports and client")
    func doubleDisconnectIdempotent() async throws {
        let fake = TeardownFakeTransport()
        let client = MCPClient(transport: fake, permissionPolicy: TeardownAllowAll())
        try await client.connect()
        await client.disconnect()
        await client.disconnect(timeout: 1)
        #expect(await client.tools().isEmpty)
        #expect(await fake.disconnectCalls == 2)

        // A fresh client that never connected also tears down cleanly twice.
        let idle = MCPClient(transport: TeardownFakeTransport())
        await idle.disconnect()
        await idle.disconnect(timeout: 0)
        #expect(await idle.tools().isEmpty)
    }

    @Test("Stream termination cancels the transport request context")
    func streamTerminationCancelsRequestContext() async throws {
        let transport = TeardownFakeTransport()
        let client = MCPClient(transport: transport, permissionPolicy: TeardownAllowAll())
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

        // Poll with a bounded deadline instead of a fixed sleep: termination
        // must be observed promptly once the consumer goes away.
        let deadline = ContinuousClock.now + .seconds(2)
        while await !transport.didObserveTermination(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.didObserveTermination())
    }

    @Test("Bounded client disconnect finishes hanging streams")
    func boundedDisconnectFinishesStreams() async throws {
        let transport = TeardownFakeTransport()
        let client = MCPClient(transport: transport, permissionPolicy: TeardownAllowAll())
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
        await client.disconnect(timeout: 1)
        _ = await consumer.result

        let deadline = ContinuousClock.now + .seconds(2)
        while await !transport.didObserveTermination(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.didObserveTermination())
        #expect(await client.tools().isEmpty)
    }
}
