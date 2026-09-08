import Foundation

extension ArchonSearchConfiguration {
    /// Search engine backend configuration.
    public struct SearchEngineSettings: Sendable, Codable, Equatable {
        public var searxngURL: URL?
        public var enabledEngines: [String]
        public var categories: [String]
        public var language: String
        public var safeSearch: Int

        public init(
            searxngURL: URL? = nil,
            enabledEngines: [String] = [],
            categories: [String] = ["general"],
            language: String = "auto",
            safeSearch: Int = 1
        ) {
            self.searxngURL = searxngURL
            self.enabledEngines = enabledEngines
            self.categories = categories
            self.language = language
            self.safeSearch = safeSearch
        }
    }

    /// Crawler backend configuration.
    public struct CrawlerSettings: Sendable, Codable, Equatable {
        public var crawl4aiURL: URL?
        public var maxDepth: Int
        public var maxConcurrentFetches: Int
        public var userAgent: String?
        public var respectRobotsTxt: Bool
        public var renderJavaScript: Bool

        public init(
            crawl4aiURL: URL? = nil,
            maxDepth: Int = 1,
            maxConcurrentFetches: Int = 5,
            userAgent: String? = nil,
            respectRobotsTxt: Bool = true,
            renderJavaScript: Bool = false
        ) {
            self.crawl4aiURL = crawl4aiURL
            self.maxDepth = maxDepth
            self.maxConcurrentFetches = maxConcurrentFetches
            self.userAgent = userAgent
            self.respectRobotsTxt = respectRobotsTxt
            self.renderJavaScript = renderJavaScript
        }
    }

    /// Timeout limits for network operations.
    public struct TimeoutSettings: Sendable, Codable, Equatable {
        public var searchTimeout: TimeInterval
        public var fetchTimeout: TimeInterval
        public var totalLatencyBudget: TimeInterval?

        public init(
            searchTimeout: TimeInterval = 10.0,
            fetchTimeout: TimeInterval = 15.0,
            totalLatencyBudget: TimeInterval? = nil
        ) {
            self.searchTimeout = searchTimeout
            self.fetchTimeout = fetchTimeout
            self.totalLatencyBudget = totalLatencyBudget
        }
    }

    /// Numerical constraints on returned elements.
    public struct LimitSettings: Sendable, Codable, Equatable {
        public var maxResults: Int
        public var maxPagesToScrape: Int
        public var maxSnippetCharacters: Int
        public var maxHighlights: Int

        public init(
            maxResults: Int = 10,
            maxPagesToScrape: Int = 3,
            maxSnippetCharacters: Int = 300,
            maxHighlights: Int = 3
        ) {
            self.maxResults = maxResults
            self.maxPagesToScrape = maxPagesToScrape
            self.maxSnippetCharacters = maxSnippetCharacters
            self.maxHighlights = maxHighlights
        }
    }
}
