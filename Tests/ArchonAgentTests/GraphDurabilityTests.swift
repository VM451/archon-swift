import Testing
import Foundation
@testable import ArchonAgent

private func makeInterruptibleGraph(
    checkpointer: (any StateCheckpointer)?
) throws -> Graph<PersistentState> {
    let builder = GraphBuilder<PersistentState>()
    builder.addNode("prepare") { state in
        var next = state
        next.data = "Prepared"
        return next
    }
    builder.addNode("criticalAction") { (_: PersistentState) in
        throw GraphInterrupt.approvalRequired(message: "Approve continuation?")
    }
    builder.addNode("finalize") { state in
        var next = state
        next.data = "Finalized after approval"
        return next
    }
    builder.setEntryPoint("prepare")
    builder.addEdge(from: "prepare", to: "criticalAction")
    builder.addEdge(from: "criticalAction", to: "finalize")
    builder.addEdge(from: "finalize", to: EndNode.id)
    return try builder.compile(checkpointer: checkpointer)
}

private actor DurabilityCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("Graph Durability Tests")
struct GraphDurabilityTests {

    @Test("SQLite crash and reopen resumes the interrupted thread to completion")
    func testSQLiteCrashReopenResume() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("durability_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let threadId = "crash-reopen-thread"

        let first = SQLiteCheckpointer(databasePath: dbPath)
        let graph = try makeInterruptibleGraph(checkpointer: first)
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: PersistentState(), threadId: threadId)
        }

        // Simulate a process restart with a brand-new checkpointer on the same file.
        let reopened = SQLiteCheckpointer(databasePath: dbPath)
        let history = try await reopened.getHistory(threadId: threadId)
        #expect(history.count == 3)
        #expect(history.last?.isInterrupted == true)

        let resumedGraph = try makeInterruptibleGraph(checkpointer: reopened)
        let final = try await resumedGraph.resume(threadId: threadId, approval: true)
        #expect(final.data == "Finalized after approval")
    }

    @Test("Forked replays are deterministic and isolated from each other")
    func testForkReplayDeterministicAndIsolated() async throws {
        let checkpointer = InMemoryCheckpointer()
        let graph = try makeInterruptibleGraph(checkpointer: checkpointer)
        let threadId = "fork-source-thread"
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: PersistentState(), threadId: threadId)
        }

        let history = try await checkpointer.getHistory(threadId: threadId)
        let interrupted = try #require(history.first(where: { $0.isInterrupted }))
        let sourceCount = history.count

        _ = try await checkpointer.fork(
            threadId: threadId,
            fromCheckpointId: interrupted.checkpointId,
            newThreadId: "fork-a"
        )
        _ = try await checkpointer.fork(
            threadId: threadId,
            fromCheckpointId: interrupted.checkpointId,
            newThreadId: "fork-b"
        )

        let finalA = try await graph.resume(threadId: "fork-a", approval: true)
        let finalB = try await graph.resume(threadId: "fork-b", approval: true)
        #expect(finalA == finalB)
        #expect(finalA.data == "Finalized after approval")

        let historyA = try await checkpointer.getHistory(threadId: "fork-a")
        let historyB = try await checkpointer.getHistory(threadId: "fork-b")
        #expect(historyA.allSatisfy { $0.threadId == "fork-a" })
        #expect(historyB.allSatisfy { $0.threadId == "fork-b" })
        let sourceAfter = try await checkpointer.getHistory(threadId: threadId)
        #expect(sourceAfter.count == sourceCount)
    }

    @Test("Checkpoint-pinned resume fails closed on a stale pin")
    func testStalePinnedResumeFailsClosed() async throws {
        let checkpointer = InMemoryCheckpointer()
        let graph = try makeInterruptibleGraph(checkpointer: checkpointer)
        let threadId = "stale-pin-thread"
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: PersistentState(), threadId: threadId)
        }

        let history = try await checkpointer.getHistory(threadId: threadId)
        let stale = try #require(history.first(where: { $0.nodeId == "prepare" }))
        let latest = try #require(history.last)
        #expect(stale.checkpointId != latest.checkpointId)

        await #expect(throws: GraphError.staleCheckpoint(
            expected: stale.checkpointId,
            latest: latest.checkpointId
        )) {
            try await graph.resume(threadId: threadId, fromCheckpointId: stale.checkpointId)
        }

        let final = try await graph.resume(threadId: threadId, fromCheckpointId: latest.checkpointId)
        #expect(final.data == "Finalized after approval")
    }

    @Test("Approval rejection leaves the thread resumable")
    func testApprovalRejectionLeavesThreadResumable() async throws {
        let checkpointer = InMemoryCheckpointer()
        let graph = try makeInterruptibleGraph(checkpointer: checkpointer)
        let threadId = "rejection-thread"
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: PersistentState(), threadId: threadId)
        }

        await #expect(throws: GraphError.self) {
            try await graph.resume(threadId: threadId, approval: false)
        }
        let final = try await graph.resume(threadId: threadId, approval: true)
        #expect(final.data == "Finalized after approval")
    }

    @Test("Cancelled stream leaves only completed checkpoints and resumes cleanly")
    func testCancellationLeavesRecoverableCheckpoints() async throws {
        let checkpointer = InMemoryCheckpointer()
        let builder = GraphBuilder<PersistentState>()
        builder.addNode("first") { state in
            var next = state
            next.data = "first-done"
            return next
        }
        builder.addNode("slow") { state in
            try await Task.sleep(nanoseconds: 200_000_000)
            var next = state
            next.data = "slow-done"
            return next
        }
        builder.addNode("last") { state in
            var next = state
            next.data = "done"
            return next
        }
        builder.setEntryPoint("first")
        builder.addEdge(from: "first", to: "slow")
        builder.addEdge(from: "slow", to: "last")
        builder.addEdge(from: "last", to: EndNode.id)
        let graph = try builder.compile(checkpointer: checkpointer)
        let threadId = "cancel-race-thread"

        let consumer = Task<Void, Error> {
            for try await event in graph.stream(initialState: PersistentState(), threadId: threadId) {
                if case .nodeCompleted(let nodeId, _, _, _) = event, nodeId == "first" {
                    break
                }
            }
        }
        try await consumer.value

        let history = try await checkpointer.getHistory(threadId: threadId)
        #expect(history.map(\.nodeId) == [StartNode.id, "first"])
        #expect(history.map(\.stepIndex) == [0, 1])

        let final = try await graph.resume(threadId: threadId)
        #expect(final.data == "done")
    }

    @Test("Ledger call-ID collision fails closed without executing")
    func testLedgerCollisionFailsClosed() async {
        let registry = ToolRegistry()
        let alphaCalls = DurabilityCallCounter()
        let betaCalls = DurabilityCallCounter()
        registry.register(ClosureTool(name: "alpha", description: "First tool") { _ in
            await alphaCalls.increment()
            return "alpha-output"
        })
        registry.register(ClosureTool(name: "beta", description: "Second tool") { _ in
            await betaCalls.increment()
            return "beta-output"
        })
        let dispatcher = ToolDispatcher(
            registry: registry,
            authorizationPolicy: ToolAuthorizationPolicy(allowedToolNames: ["alpha", "beta"]),
            effectLedger: InMemoryToolEffectLedger()
        )

        let first = await dispatcher.execute(call: ToolCall(id: "shared-id", name: "alpha", arguments: "{}"))
        #expect(first.content == "alpha-output")

        let collision = await dispatcher.execute(call: ToolCall(id: "shared-id", name: "beta", arguments: "{}"))
        #expect(collision.content.contains("Unable to reserve tool effect safely"))
        #expect(await alphaCalls.value == 1)
        #expect(await betaCalls.value == 0)
    }

    @Test("Ledger releases a failed reservation so a retry executes once more")
    func testLedgerReleaseAfterFailureAllowsRetry() async {
        let registry = ToolRegistry()
        let calls = DurabilityCallCounter()
        registry.register(ClosureTool(name: "flaky", description: "Fails once") { _ in
            await calls.increment()
            if await calls.value == 1 {
                throw ToolValidationError.invalidArguments("boom")
            }
            return "recovered"
        })
        let dispatcher = ToolDispatcher(
            registry: registry,
            authorizationPolicy: ToolAuthorizationPolicy(allowedToolNames: ["flaky"]),
            effectLedger: InMemoryToolEffectLedger()
        )
        let call = ToolCall(id: "retry-1", name: "flaky", arguments: "{}")

        let failed = await dispatcher.execute(call: call)
        #expect(failed.content.contains("Execution Error"))
        let retried = await dispatcher.execute(call: call)
        #expect(retried.content == "recovered")
        let replayed = await dispatcher.execute(call: call)
        #expect(replayed.content == "recovered")
        #expect(await calls.value == 2)
    }

    @Test("Concurrent duplicate tool calls execute the side effect exactly once")
    func testLedgerConcurrentReserveExecutesOnce() async {
        let registry = ToolRegistry()
        let calls = DurabilityCallCounter()
        registry.register(ClosureTool(name: "slow-once", description: "Slow tool") { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await calls.increment()
            return "done"
        })
        let dispatcher = ToolDispatcher(
            registry: registry,
            authorizationPolicy: ToolAuthorizationPolicy(allowedToolNames: ["slow-once"]),
            effectLedger: InMemoryToolEffectLedger()
        )

        let results = await withTaskGroup(of: ChatMessage.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await dispatcher.execute(call: ToolCall(id: "race", name: "slow-once", arguments: "{}"))
                }
            }
            var collected: [ChatMessage] = []
            for await message in group {
                collected.append(message)
            }
            return collected
        }

        #expect(await calls.value == 1)
        #expect(results.count == 2)
        for message in results {
            #expect(message.content == "done" || message.content.contains("already executing"))
        }
    }
}
