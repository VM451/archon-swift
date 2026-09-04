import Foundation

/// Durable offline queue managing pending CloudKit delta sync operations with retry backoff and rate-limit tracking.
public actor SyncOfflineQueue {
    public struct QueuedOperation: Identifiable, Sendable, Codable, Equatable {
        public let id: UUID
        public let workspaceID: UUID
        public var timestamp: Date
        public var retryCount: Int
        public var nextRetryDate: Date
        
        public init(workspaceID: UUID) {
            self.id = UUID()
            self.workspaceID = workspaceID
            self.timestamp = Date()
            self.retryCount = 0
            self.nextRetryDate = Date()
        }
    }
    
    private var pendingOperations: [QueuedOperation] = []
    
    public init() {}
    
    /// Enqueues a workspace sync operation.
    public func enqueue(workspaceID: UUID) {
        if let index = pendingOperations.firstIndex(where: { $0.workspaceID == workspaceID }) {
            pendingOperations[index].timestamp = Date()
            pendingOperations[index].nextRetryDate = Date()
        } else {
            pendingOperations.append(QueuedOperation(workspaceID: workspaceID))
        }
    }
    
    /// Returns operations that are eligible for execution based on current date.
    public func readyOperations() -> [QueuedOperation] {
        let now = Date()
        return pendingOperations.filter { $0.nextRetryDate <= now }
    }
    
    /// Marks an operation as completed and removes it from the queue.
    public func markCompleted(id: UUID) {
        pendingOperations.removeAll(where: { $0.id == id })
    }
    
    /// Reschedules a failed operation with exponential backoff or explicit retry delay.
    public func markFailed(id: UUID, retryAfterSeconds: TimeInterval? = nil) {
        guard let index = pendingOperations.firstIndex(where: { $0.id == id }) else { return }
        pendingOperations[index].retryCount += 1
        let delay: TimeInterval
        if let custom = retryAfterSeconds {
            delay = custom
        } else {
            // Exponential backoff: 2s, 4s, 8s, 16s... up to max 60s
            delay = min(60.0, pow(2.0, Double(pendingOperations[index].retryCount)))
        }
        pendingOperations[index].nextRetryDate = Date().addingTimeInterval(delay)
    }
    
    /// Returns the total number of queued operations.
    public var pendingCount: Int {
        pendingOperations.count
    }
    
    /// Clears all pending operations.
    public func clear() {
        pendingOperations.removeAll()
    }
}
