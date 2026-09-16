import Testing
import Foundation
@testable import ArchonSandbox

private actor CallGate {
    private var arrived = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() {
        arrived += 1
        if released { return }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Sandbox Threat Model Tests")
struct SandboxThreatModelTests {
    private func collectEvents(
        from engine: SandboxEngine,
        count: Int
    ) -> Task<[SandboxEvent], Never> {
        Task {
            var events: [SandboxEvent] = []
            for await event in engine.eventStream {
                events.append(event)
                if events.count >= count { break }
            }
            return events
        }
    }

    private func isQuotaError(_ event: SandboxEvent) -> Bool {
        if case .uncaughtError(let message, _) = event {
            return message.contains("quota exceeded")
        }
        return false
    }

    private func isConcurrencyError(_ event: SandboxEvent) -> Bool {
        if case .uncaughtError(let message, _) = event {
            return message.contains("concurrency limit exceeded")
        }
        return false
    }

    private func isSizeError(_ event: SandboxEvent) -> Bool {
        if case .uncaughtError(let message, _) = event {
            return message.contains("exceeds the configured size limit")
        }
        return false
    }

    @Test("Oversize bridge message is rejected with an error event")
    func testBridgeMessageSizeBound() async {
        let engine = SandboxEngine(workspace: SandboxWorkspace(name: "bound"))
        let collector = collectEvents(from: engine, count: 2)
        await engine.handleIncomingJSON(String(repeating: "x", count: 256 * 1024 + 1))
        let events = await collector.value
        #expect(events.count == 2)
        #expect(events.contains(where: isSizeError))
    }

    @Test("Thirty-third concurrent tool call is rejected while 32 run")
    func testToolCallConcurrencyCap() async {
        let gate = CallGate()
        var configuration = SandboxConfiguration()
        configuration.allowedSandboxToolNames = ["gate"]
        let engine = SandboxEngine(
            workspace: SandboxWorkspace(name: "cap"),
            configuration: configuration
        )
        await engine.registerTool(ClosureAgentTool(name: "gate", description: "blocking gate") { _ in
            await gate.arriveAndWait()
            await gate.waitForRelease()
            return "{}"
        })

        let collector = collectEvents(from: engine, count: 34)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<33 {
                group.addTask {
                    await engine.handleIncomingJSON(
                        #"{"type":"TOOL_CALL","id":"call-\#(index)","toolName":"gate","arguments":{}}"#
                    )
                }
            }
        }
        // Every increment is processed before any execution can finish: the
        // gate only releases after all 33 calls returned, so the cap decision
        // is deterministic.
        await gate.release()
        let events = await collector.value

        let toolCalls = events.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolCalls.count == 32)
        #expect(events.filter(isConcurrencyError).count == 1)
    }

    @Test("Workspace quota accepts the boundary file and rejects overflow")
    func testWorkspaceQuotaBoundary() async {
        let engine = SandboxEngine(
            workspace: SandboxWorkspace(name: "quota", files: []),
            configuration: SandboxConfiguration(maxMemoryMB: 1)
        )
        let collector = collectEvents(from: engine, count: 2)
        await engine.updateFile(SandboxFile(path: "exact.bin", text: String(repeating: "a", count: 1_048_576)))
        await engine.updateFile(SandboxFile(path: "overflow.bin", text: String(repeating: "b", count: 1_048_577)))
        let events = await collector.value

        let workspace = await engine.getWorkspace()
        #expect(workspace.file(at: "exact.bin") != nil)
        #expect(workspace.file(at: "overflow.bin") == nil)
        #expect(events.filter(isQuotaError).count == 1)
    }

    @Test("Malformed bridge input is ignored and the engine stays healthy")
    func testMalformedBridgeInputIgnored() async {
        let engine = SandboxEngine(workspace: SandboxWorkspace(name: "malformed"))
        let collector = collectEvents(from: engine, count: 2)
        await engine.handleIncomingJSON("this is not json {{{")
        await engine.handleIncomingJSON(#"{"type":"CONSOLE","level":"info","message":"still alive"}"#)
        let events = await collector.value

        #expect(events.count == 2)
        if case .consoleLog(_, let message, _) = events[1] {
            #expect(message == "still alive")
        } else {
            Issue.record("Expected a console event after malformed input, got \(events[1]).")
        }
        #expect(!events.contains { event in
            if case .uncaughtError = event { return true }
            return false
        })
    }
}
