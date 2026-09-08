import Foundation

/// Configuration options for ArchonSearch 2.0 orchestration.
public struct ArchonSearchConfiguration: Sendable, Codable, Equatable {
    /// Routing mode determining how search and crawl queries are dispatched.
    public enum RoutingMode: String, Sendable, Codable, CaseIterable {
        case automatic, preferCrawler, preferNative, nativeOnly, crawlerOnly
    }
    

    public var routingMode: RoutingMode
    public var searchEngine: SearchEngineSettings
    public var crawler: CrawlerSettings
    public var timeouts: TimeoutSettings
    public var limits: LimitSettings

    public init(
        routingMode: RoutingMode = .nativeOnly,
        searchEngine: SearchEngineSettings = SearchEngineSettings(searxngURL: nil),
        crawler: CrawlerSettings = CrawlerSettings(crawl4aiURL: nil),
        timeouts: TimeoutSettings = TimeoutSettings(),
        limits: LimitSettings = LimitSettings()
    ) {
        self.routingMode = routingMode
        self.searchEngine = searchEngine
        self.crawler = crawler
        self.timeouts = timeouts
        self.limits = limits
    }

    /// Factory for 100% on-device native search without local or remote companion servers.
    public static func onDevice() -> ArchonSearchConfiguration {
        ArchonSearchConfiguration(
            routingMode: .nativeOnly,
            searchEngine: SearchEngineSettings(searxngURL: nil),
            crawler: CrawlerSettings(crawl4aiURL: nil),
            timeouts: TimeoutSettings(searchTimeout: 8.0, fetchTimeout: 12.0),
            limits: LimitSettings(maxResults: 10, maxPagesToScrape: 5)
        )
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

    /// Alias for `localFirst`, explicitly naming optional Docker companion instances.
    public static func dockerCompanion(
        searxngURL: URL? = URL(string: "http://localhost:8080"),
        crawl4aiURL: URL? = URL(string: "http://localhost:11235")
    ) -> ArchonSearchConfiguration {
        localFirst(searxngURL: searxngURL, crawl4aiURL: crawl4aiURL)
    }
}
