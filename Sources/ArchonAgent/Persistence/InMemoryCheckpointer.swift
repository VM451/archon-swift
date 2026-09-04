import Foundation

/// Thread-safe in-memory checkpointer actor for testing, rapid prototyping, and transient sessions.
public actor InMemoryCheckpointer: StateCheckpointer {
    private var recordsByThread: [String: [CheckpointRecord]] = [:]

    public init() {}

    public func save(record: CheckpointRecord) async throws {
        var threadRecords = recordsByThread[record.threadId] ?? []
        threadRecords.append(record)
        recordsByThread[record.threadId] = threadRecords
    }

    public func getLatest<S: AgentState>(threadId: String, as type: S.Type) async throws -> TypedCheckpoint<S>? {
        guard let latest = recordsByThread[threadId]?.last else {
            return nil
        }
        let decodedState = try latest.decodeState(as: S.self)
        return TypedCheckpoint(
            checkpointId: latest.checkpointId,
            threadId: latest.threadId,
            runId: latest.runId,
            nodeId: latest.nodeId,
            stepIndex: latest.stepIndex,
            timestamp: latest.timestamp,
            state: decodedState,
            isInterrupted: latest.isInterrupted,
            interruptMessage: latest.interruptMessage,
            metadata: latest.metadata
        )
    }

    public func getHistory(threadId: String) async throws -> [CheckpointRecord] {
        return recordsByThread[threadId] ?? []
    }

    public func deleteThread(threadId: String) async throws {
        recordsByThread.removeValue(forKey: threadId)
    }

    public func fork(threadId: String, fromCheckpointId: String, newThreadId: String) async throws -> CheckpointRecord {
        guard let threadRecords = recordsByThread[threadId],
              let target = threadRecords.first(where: { $0.checkpointId == fromCheckpointId }) else {
            throw GraphError.graphHalted(reason: "Checkpoint '\(fromCheckpointId)' not found in thread '\(threadId)'.")
        }

        let forked = CheckpointRecord(
            checkpointId: UUID().uuidString,
            threadId: newThreadId,
            runId: UUID().uuidString,
            nodeId: target.nodeId,
            stepIndex: 0,
            timestamp: Date(),
            stateData: target.stateData,
            isInterrupted: false,
            interruptMessage: nil,
            metadata: target.metadata
        )

        recordsByThread[newThreadId] = [forked]
        return forked
    }
}
