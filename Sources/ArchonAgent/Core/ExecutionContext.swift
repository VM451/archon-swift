import Foundation

/// ExecutionContext holds the runtime environment, metadata, step tracking,
/// thread isolation identifiers, and cancellation tokens for an active graph execution.
public struct ExecutionContext: Sendable {
    /// Unique thread identifier representing a multi-turn conversation or execution instance.
    public let threadId: String

    /// Unique identifier of the current execution run.
    public let runId: String

    /// Current node being evaluated.
    public let currentNodeId: String

    /// Zero-based sequential step counter in the current graph run.
    public let stepIndex: Int

    /// Creation timestamp of this execution context.
    public let timestamp: Date

    /// Arbitrary sendable metadata associated with the execution.
    public let metadata: [String: String]

    public init(
        threadId: String = UUID().uuidString,
        runId: String = UUID().uuidString,
        currentNodeId: String = "__start__",
        stepIndex: Int = 0,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.threadId = threadId
        self.runId = runId
        self.currentNodeId = currentNodeId
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.metadata = metadata
    }

    /// Creates a next-step context for the subsequent node transition.
    public func advancing(to nextNodeId: String) -> ExecutionContext {
        ExecutionContext(
            threadId: self.threadId,
            runId: self.runId,
            currentNodeId: nextNodeId,
            stepIndex: self.stepIndex + 1,
            timestamp: Date(),
            metadata: self.metadata
        )
    }

    /// Inserts or updates a metadata key-value pair.
    public func setting(key: String, value: String) -> ExecutionContext {
        var newMeta = self.metadata
        newMeta[key] = value
        return ExecutionContext(
            threadId: self.threadId,
            runId: self.runId,
            currentNodeId: self.currentNodeId,
            stepIndex: self.stepIndex,
            timestamp: self.timestamp,
            metadata: newMeta
        )
    }
}
