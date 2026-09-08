import Foundation

/// Health diagnostics report describing availability of Crawl4AI and NativeReader retrieval backends.
public struct RetrievalHealthReport: Sendable, Codable, Hashable {
    public let isCrawlerAvailable: Bool
    public let isNativeAvailable: Bool
    public let crawlerEndpoint: URL?
    public let lastCheckedAt: Date
    public let details: [String: String]

    public var isHealthy: Bool {
        isCrawlerAvailable || isNativeAvailable
    }

    public init(
        isCrawlerAvailable: Bool,
        isNativeAvailable: Bool,
        crawlerEndpoint: URL? = nil,
        lastCheckedAt: Date = Date(),
        details: [String: String] = [:]
    ) {
        self.isCrawlerAvailable = isCrawlerAvailable
        self.isNativeAvailable = isNativeAvailable
        self.crawlerEndpoint = crawlerEndpoint
        self.lastCheckedAt = lastCheckedAt
        self.details = details
    }
}
