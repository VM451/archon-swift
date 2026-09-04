import Testing
import Foundation
#if canImport(SwiftData)
import SwiftData
#endif
@testable import ArchonAgent

struct PersistentState: AgentState {
    var step: Int = 0
    var data: String = ""
}

@Suite("State Checkpointer Tests")
struct CheckpointerTests {

    @Test("InMemoryCheckpointer saves, retrieves latest, and gets history")
    func testInMemoryCheckpointer() async throws {
        let checkpointer = InMemoryCheckpointer()
        let threadId = UUID().uuidString

        let record1 = CheckpointRecord(
            threadId: threadId,
            nodeId: "nodeA",
            stepIndex: 0,
            state: PersistentState(step: 1, data: "alpha")
        )
        try await checkpointer.save(record: record1)

        let record2 = CheckpointRecord(
            threadId: threadId,
            nodeId: "nodeB",
            stepIndex: 1,
            state: PersistentState(step: 2, data: "beta")
        )
        try await checkpointer.save(record: record2)

        let latest = try await checkpointer.getLatest(threadId: threadId, as: PersistentState.self)
        #expect(latest != nil)
        #expect(latest?.state.data == "beta")
        #expect(latest?.stepIndex == 1)

        let history = try await checkpointer.getHistory(threadId: threadId)
        #expect(history.count == 2)

        // Fork test
        let forked = try await checkpointer.fork(
            threadId: threadId,
            fromCheckpointId: record1.checkpointId,
            newThreadId: "forked-thread"
        )
        #expect(forked.threadId == "forked-thread")
        let forkedLatest = try await checkpointer.getLatest(threadId: "forked-thread", as: PersistentState.self)
        #expect(forkedLatest?.state.data == "alpha")
    }

    @Test("SQLiteCheckpointer file persistence")
    func testSQLiteCheckpointer() async throws {
        let tempDb = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).sqlite").path
        let checkpointer = SQLiteCheckpointer(databasePath: tempDb)
        let threadId = "sqlite-test-thread"

        let record = CheckpointRecord(
            threadId: threadId,
            nodeId: "sqliteNode",
            stepIndex: 0,
            state: PersistentState(step: 42, data: "sqlite-saved")
        )
        try await checkpointer.save(record: record)

        let latest = try await checkpointer.getLatest(threadId: threadId, as: PersistentState.self)
        #expect(latest?.state.step == 42)
        #expect(latest?.state.data == "sqlite-saved")
    }
}
