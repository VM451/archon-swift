import Foundation

/// Sendable representation of a crawl node inside the scheduler queue.
public struct QueueNodeInfo: Sendable, Codable {
    public let urlString: String
    public let status: String
    public let priority: Int
    public let parentURLString: String?
    public let backoffUntil: Date?
    public let depth: Int
    public let failureCount: Int
    public let retryCount: Int

    public init(
        urlString: String,
        status: String,
        priority: Int,
        parentURLString: String? = nil,
        backoffUntil: Date? = nil,
        depth: Int = 0,
        failureCount: Int = 0,
        retryCount: Int = 0
    ) {
        self.urlString = urlString
        self.status = status
        self.priority = priority
        self.parentURLString = parentURLString
        self.backoffUntil = backoffUntil
        self.depth = depth
        self.failureCount = failureCount
        self.retryCount = retryCount
    }
}
