import Foundation

/// Protocol defining storage backends for persisting graph states across application lifecycles.
public protocol StateCheckpointer: Sendable {
    /// Persists a new state checkpoint record.
    func save(record: CheckpointRecord) async throws

    /// Retrieves the most recent checkpoint for a given thread ID and decodes its state.
    func getLatest<S: AgentState>(threadId: String, as type: S.Type) async throws -> TypedCheckpoint<S>?

    /// Retrieves full execution history for a given thread in chronological order.
    func getHistory(threadId: String) async throws -> [CheckpointRecord]

    /// Deletes all checkpoints associated with a thread ID.
    func deleteThread(threadId: String) async throws

    /// Forks a previous historical checkpoint into a brand-new independent thread.
    func fork(threadId: String, fromCheckpointId: String, newThreadId: String) async throws -> CheckpointRecord
}
