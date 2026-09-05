import Testing
import Foundation
@testable import ArchonAgent

@Suite("Time Travel & State Replay Tests")
struct TimeTravelTests {

    @Test("TimeTravelEngine inspects historical state and forks execution")
    func testTimeTravelAndFork() async throws {
        let checkpointer = InMemoryCheckpointer()
        let engine = TimeTravelEngine(checkpointer: checkpointer)
        let threadId = "time-travel-thread"

        let state1 = PersistentState(step: 1, data: "v1")
        let rec1 = CheckpointRecord(checkpointId: "cp-1", threadId: threadId, nodeId: "start", stepIndex: 0, state: state1)
        try await checkpointer.save(record: rec1)

        let state2 = PersistentState(step: 2, data: "v2")
        let rec2 = CheckpointRecord(checkpointId: "cp-2", threadId: threadId, nodeId: "middle", stepIndex: 1, state: state2)
        try await checkpointer.save(record: rec2)

        let inspected = try await engine.inspectState(at: "cp-1", threadId: threadId, as: PersistentState.self)
        #expect(inspected.data == "v1")

        let forked = try await engine.branch(fromCheckpointId: "cp-1", onThread: threadId, newThreadId: "fork-branch")
        #expect(forked.threadId == "fork-branch")
    }
}

@Suite("Human-in-the-Loop Interrupt Tests")
struct HumanInTheLoopTests {

    @Test("Graph halts on GraphInterrupt.approvalRequired and resumes upon user confirmation")
    func testHumanInTheLoopApproval() async throws {
        let checkpointer = InMemoryCheckpointer()
        let builder = GraphBuilder<PersistentState>()

        builder.addNode("prepare") { state in
            var s = state
            s.data = "Prepared"
            return s
        }

        builder.addNode("criticalAction") { (state: PersistentState) in
            throw GraphInterrupt.approvalRequired(message: "Approve database wipe?")
        }

        builder.addNode("finalize") { state in
            var s = state
            s.data = "Finalized after approval"
            return s
        }

        builder.setEntryPoint("prepare")
        builder.addEdge(from: "prepare", to: "criticalAction")
        builder.addEdge(from: "criticalAction", to: "finalize")
        builder.addEdge(from: "finalize", to: EndNode.id)

        let graph = try builder.compile(checkpointer: checkpointer)
        let threadId = "hitl-thread"

        // Initial run should halt at criticalAction
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: PersistentState(), threadId: threadId)
        }

        // Resume after human approval
        let resumedResult = try await graph.resume(threadId: threadId, approval: true)
        #expect(resumedResult.data == "Finalized after approval")
    }
}
