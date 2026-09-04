import Foundation
#if canImport(SwiftData)
import SwiftData

/// SwiftData persistent entity representing a state checkpoint.
@Model
public final class CheckpointEntity {
    @Attribute(.unique) public var id: String
    public var checkpointId: String
    public var threadId: String
    public var runId: String
    public var nodeId: String
    public var stepIndex: Int
    public var timestamp: Date
    @Attribute(.externalStorage) public var stateData: Data
    public var isInterrupted: Bool
    public var interruptMessage: String?
    public var metadataJSON: String

    public init(
        id: String,
        checkpointId: String,
        threadId: String,
        runId: String,
        nodeId: String,
        stepIndex: Int,
        timestamp: Date,
        stateData: Data,
        isInterrupted: Bool,
        interruptMessage: String?,
        metadataJSON: String
    ) {
        self.id = id
        self.checkpointId = checkpointId
        self.threadId = threadId
        self.runId = runId
        self.nodeId = nodeId
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.stateData = stateData
        self.isInterrupted = isInterrupted
        self.interruptMessage = interruptMessage
        self.metadataJSON = metadataJSON
    }
}

/// SwiftData-backed StateCheckpointer providing deep Apple platform persistence,
/// seamless SwiftUI Query synchronization, and CoreData cloud sync capabilities.
@ModelActor
public actor SwiftDataCheckpointer: StateCheckpointer {
    public static func inMemory() throws -> SwiftDataCheckpointer {
        let schema = Schema([CheckpointEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataCheckpointer(modelContainer: container)
    }

    public func save(record: CheckpointRecord) async throws {
        let metaJson = (try? JSONSerialization.data(withJSONObject: record.metadata)) ?? Data()
        let metaString = String(data: metaJson, encoding: .utf8) ?? "{}"

        let entity = CheckpointEntity(
            id: record.id,
            checkpointId: record.checkpointId,
            threadId: record.threadId,
            runId: record.runId,
            nodeId: record.nodeId,
            stepIndex: record.stepIndex,
            timestamp: record.timestamp,
            stateData: try CheckpointStateProtector.seal(record.stateData),
            isInterrupted: record.isInterrupted,
            interruptMessage: record.interruptMessage,
            metadataJSON: metaString
        )

        modelContext.insert(entity)
        try modelContext.save()
    }

    public func getLatest<S: AgentState>(threadId: String, as type: S.Type) async throws -> TypedCheckpoint<S>? {
        let history = try await getHistory(threadId: threadId)
        guard let latest = history.last else {
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
        let predicate = #Predicate<CheckpointEntity> { entity in
            entity.threadId == threadId
        }
        var descriptor = FetchDescriptor<CheckpointEntity>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.stepIndex, order: .forward)]

        let entities = try modelContext.fetch(descriptor)
        return try entities.map { entity in
            var meta: [String: String] = [:]
            if let data = entity.metadataJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                meta = parsed
            }
            return CheckpointRecord(
                checkpointId: entity.checkpointId,
                threadId: entity.threadId,
                runId: entity.runId,
                nodeId: entity.nodeId,
                stepIndex: entity.stepIndex,
                timestamp: entity.timestamp,
                stateData: try CheckpointStateProtector.open(entity.stateData),
                isInterrupted: entity.isInterrupted,
                interruptMessage: entity.interruptMessage,
                metadata: meta
            )
        }
    }

    public func deleteThread(threadId: String) async throws {
        let predicate = #Predicate<CheckpointEntity> { entity in
            entity.threadId == threadId
        }
        try modelContext.delete(model: CheckpointEntity.self, where: predicate)
        try modelContext.save()
    }

    public func fork(threadId: String, fromCheckpointId: String, newThreadId: String) async throws -> CheckpointRecord {
        let history = try await getHistory(threadId: threadId)
        guard let target = history.first(where: { $0.checkpointId == fromCheckpointId }) else {
            throw GraphError.graphHalted(reason: "Checkpoint '\(fromCheckpointId)' not found in SwiftData.")
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

        try await save(record: forked)
        return forked
    }
}
#endif
