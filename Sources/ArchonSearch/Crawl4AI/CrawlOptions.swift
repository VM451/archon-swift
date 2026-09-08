import Foundation

/// Configuration options for dispatching page crawls via Crawl4AI.
public struct CrawlOptions: Sendable, Codable, Hashable {
    public let priority: Int
    public let wordCountThreshold: Int?
    public let cssSelector: String?
    public let magic: Bool
    public let simulateUser: Bool
    public let extractionStrategy: String?

    public init(
        priority: Int = 10,
        wordCountThreshold: Int? = nil,
        cssSelector: String? = nil,
        magic: Bool = false,
        simulateUser: Bool = false,
        extractionStrategy: String? = nil
    ) {
        self.priority = priority
        self.wordCountThreshold = wordCountThreshold
        self.cssSelector = cssSelector
        self.magic = magic
        self.simulateUser = simulateUser
        self.extractionStrategy = extractionStrategy
    }
}
