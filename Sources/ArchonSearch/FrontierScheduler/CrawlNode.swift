import Foundation
import SwiftData

public enum CrawlStatus: String, Codable, Sendable {
    case pending
    case crawling
    case completed
    case failed
}

@Model
public final class CrawlNode {
    @Attribute(.unique)
    public var urlString: String
    
    public var statusValue: String
    public var priority: Int
    public var retryCount: Int
    public var lastAttemptedAt: Date?
    public var domain: String
    public var addedAt: Date
    public var robotsChecked: Bool
    public var parentURLString: String?
    public var backoffUntil: Date?
    /// Crawl depth from the seed URL (0 for seeds). Deeper nodes score lower.
    public var depth: Int
    /// Host failures recorded against this node. Decays priority.
    public var failureCount: Int

    public init(
        urlString: String,
        status: CrawlStatus = .pending,
        priority: Int = 0,
        retryCount: Int = 0,
        lastAttemptedAt: Date? = nil,
        domain: String,
        addedAt: Date = Date(),
        robotsChecked: Bool = false,
        parentURLString: String? = nil,
        backoffUntil: Date? = nil,
        depth: Int = 0,
        failureCount: Int = 0
    ) {
        self.urlString = urlString
        self.statusValue = status.rawValue
        self.priority = priority
        self.retryCount = retryCount
        self.lastAttemptedAt = lastAttemptedAt
        self.domain = domain
        self.addedAt = addedAt
        self.robotsChecked = robotsChecked
        self.parentURLString = parentURLString
        self.backoffUntil = backoffUntil
        self.depth = depth
        self.failureCount = failureCount
    }
    
    public var status: CrawlStatus {
        get { CrawlStatus(rawValue: statusValue) ?? .pending }
        set { statusValue = newValue.rawValue }
    }
}
