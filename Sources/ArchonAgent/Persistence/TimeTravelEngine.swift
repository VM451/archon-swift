import Foundation

/// TimeTravelEngine provides developers and UI components with the ability to
/// inspect past state snapshots, calculate step-by-step diffs, and fork execution paths.
public final class TimeTravelEngine: Sendable {
    private let checkpointer: any StateCheckpointer

    public init(checkpointer: any StateCheckpointer) {
        self.checkpointer = checkpointer
    }

    /// Fetches all recorded checkpoints for a specific execution thread.
    public func fetchHistory(threadId: String) async throws -> [CheckpointRecord] {
        try await checkpointer.getHistory(threadId: threadId)
    }

    /// Reconstructs the state at a specific checkpoint step.
    public func inspectState<S: AgentState>(at checkpointId: String, threadId: String, as type: S.Type) async throws -> S {
        let history = try await checkpointer.getHistory(threadId: threadId)
        guard let record = history.first(where: { $0.checkpointId == checkpointId }) else {
            throw GraphError.graphHalted(reason: "Checkpoint '\(checkpointId)' not found.")
        }
        return try record.decodeState(as: S.self)
    }

    /// Creates a new branch from a historical checkpoint, enabling state replay & exploratory branching.
    public func branch(fromCheckpointId checkpointId: String, onThread threadId: String, newThreadId: String = UUID().uuidString) async throws -> CheckpointRecord {
        try await checkpointer.fork(threadId: threadId, fromCheckpointId: checkpointId, newThreadId: newThreadId)
    }
}
