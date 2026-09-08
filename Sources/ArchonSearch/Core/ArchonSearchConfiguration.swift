import Foundation

/// Configuration options for ArchonSearch 2.0 orchestration.
public struct ArchonSearchConfiguration: Sendable, Codable, Equatable {
    
    /// Routing mode determining how search and crawl queries are dispatched.
    public enum RoutingMode: String, Sendable, Codable, CaseIterable {
        case automatic
        case preferCrawler
        case preferNative
        case nativeOnly
        case crawlerOnly
    }
    
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
    
    public var routingMode: RoutingMode
    public var searchEngine: SearchEngineSettings
    public var crawler: CrawlerSettings
    public var timeouts: TimeoutSettings
    public var limits: LimitSettings
    
    public init(
        routingMode: RoutingMode = .automatic,
        searchEngine: SearchEngineSettings = SearchEngineSettings(),
        crawler: CrawlerSettings = CrawlerSettings(),
        timeouts: TimeoutSettings = TimeoutSettings(),
        limits: LimitSettings = LimitSettings()
    ) {
        self.routingMode = routingMode
        self.searchEngine = searchEngine
        self.crawler = crawler
        self.timeouts = timeouts
        self.limits = limits
    }
    
    /// Factory for local-first execution prioritizing local instances of SearXNG and Crawl4AI.
    public static func localFirst(
        searxngURL: URL? = URL(string: "http://localhost:8080"),
        crawl4aiURL: URL? = URL(string: "http://localhost:11235")
    ) -> ArchonSearchConfiguration {
        ArchonSearchConfiguration(
            routingMode: .preferCrawler,
            searchEngine: SearchEngineSettings(searxngURL: searxngURL),
            crawler: CrawlerSettings(crawl4aiURL: crawl4aiURL),
            timeouts: TimeoutSettings(searchTimeout: 8.0, fetchTimeout: 12.0),
            limits: LimitSettings(maxResults: 10, maxPagesToScrape: 5)
        )
    }
}
