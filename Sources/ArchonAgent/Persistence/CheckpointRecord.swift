import Foundation

/// Represents a persistent snapshot of an agent's execution state at a point in time.
public struct CheckpointRecord: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let checkpointId: String
    public let threadId: String
    public let runId: String
    public let nodeId: String
    public let stepIndex: Int
    public let timestamp: Date
    public let stateData: Data
    public let isInterrupted: Bool
    public let interruptMessage: String?
    public let metadata: [String: String]

    public init<S: AgentState>(
        checkpointId: String = UUID().uuidString,
        threadId: String,
        runId: String = UUID().uuidString,
        nodeId: String,
        stepIndex: Int,
        timestamp: Date = Date(),
        state: S,
        isInterrupted: Bool = false,
        interruptMessage: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = checkpointId
        self.checkpointId = checkpointId
        self.threadId = threadId
        self.runId = runId
        self.nodeId = nodeId
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.isInterrupted = isInterrupted
        self.interruptMessage = interruptMessage
        self.metadata = metadata

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.stateData = (try? encoder.encode(state)) ?? Data()
    }

    public init(
        checkpointId: String,
        threadId: String,
        runId: String,
        nodeId: String,
        stepIndex: Int,
        timestamp: Date,
        stateData: Data,
        isInterrupted: Bool = false,
        interruptMessage: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = checkpointId
        self.checkpointId = checkpointId
        self.threadId = threadId
        self.runId = runId
        self.nodeId = nodeId
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.stateData = stateData
        self.isInterrupted = isInterrupted
        self.interruptMessage = interruptMessage
        self.metadata = metadata
    }

    /// Decodes the underlying state data into the strongly-typed AgentState.
    public func decodeState<S: AgentState>(as type: S.Type) throws -> S {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(S.self, from: stateData)
    }
}

/// Strongly typed container holding the decoded state alongside its checkpoint metadata.
public struct TypedCheckpoint<S: AgentState>: Sendable {
    public let checkpointId: String
    public let threadId: String
    public let runId: String
    public let nodeId: String
    public let stepIndex: Int
    public let timestamp: Date
    public let state: S
    public let isInterrupted: Bool
    public let interruptMessage: String?
    public let metadata: [String: String]
}
