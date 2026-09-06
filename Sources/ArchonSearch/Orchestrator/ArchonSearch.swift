import Foundation
import SwiftData

/// The public facade and entry point for ArchonSearch.
/// Coordinates the discovery engine, background crawl queue, stealth scraper, and local semantic/LLM core.
public final class ArchonSearch: Sendable {
    internal let discoveryEngine: DiscoveryEngine
    internal let semanticCore: ArchonSemanticCore
    internal let structuredExtractionHandler: StructuredExtractionHandler?
    internal let modelContainer: ModelContainer?
    internal let queueActor: FrontierQueueActor?
    internal let initializationFailure: String?
    internal let localWorkspaceRoots: [URL]
    
    /// Initializes a new ArchonSearch instance.
    /// By default, initializes an in-memory SwiftData database for crawling.
    public init(
        structuredExtractionHandler: StructuredExtractionHandler? = nil,
        localWorkspaceRoots: [URL] = []
    ) {
        self.localWorkspaceRoots = localWorkspaceRoots
        self.discoveryEngine = DiscoveryEngine(localWorkspaceRoots: localWorkspaceRoots)
        self.semanticCore = ArchonSemanticCore(structuredExtractionHandler: structuredExtractionHandler)
        self.structuredExtractionHandler = structuredExtractionHandler
        
        let container: ModelContainer?
        let initializationFailure: String?
        do {
            let schema = Schema([CrawlNode.self, ScrapedPage.self])
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            initializationFailure = nil
        } catch {
            container = nil
            initializationFailure = String(describing: error)
        }
        self.modelContainer = container
        self.queueActor = container.map { FrontierQueueActor(modelContainer: $0) }
        self.initializationFailure = initializationFailure
    }
    
    /// Runs an autonomous, stealth, on-device search and structured information extraction.
    /// - Parameters:
    ///   - query: The target search query.
    ///   - type: The Generable struct type to extract.
    ///   - maxPages: The maximum number of distinct pages to scrape.
    ///   - source: The discovery source (DuckDuckGo, Wikipedia, local files, or public social platforms).
    ///   - scrapeConfig: Scrape settings (interactive actions, Markdown conversion).
    ///   - deepResearchDepth: The depth of dynamic link harvesting to perform (0 = single level).
    /// - Returns: A ResearchOutput containing extracted data, citations, and the search node tree.
    public func research<T: ArchonGenerable & Codable & Sendable>(
        query: String,
        extracting type: T.Type,
        maxPages: Int = 3,
        source: DiscoverySource = .duckDuckGo,
        scrapeConfig: ScrapeConfiguration = ScrapeConfiguration(),
        deepResearchDepth: Int = 0,
        timeout: TimeInterval? = nil
    ) async throws -> ResearchOutput<T> {
        guard let queueActor else {
            throw SearchError.initializationFailed(reason: initializationFailure ?? "The crawl store could not be initialized.")
        }

        let startTime = Date()
        // 1. Discover initial URLs
        let seedURLs = try await discoveryEngine.search(query: query, source: source)
        
        // 2. Enqueue discovered URLs into background SwiftData crawl queue
        try await queueActor.enqueue(
            urls: seedURLs,
            priority: 10,
            parentURLString: nil,
            localWorkspaceRoots: localWorkspaceRoots
        )
        var depthByURL = [String: Int]()
        for seedURL in seedURLs {
            depthByURL[seedURL.absoluteString] = 0
        }
        
        var firstResult: T?
        var pagesScraped = 0
        var scrapedPagesData = [ScrapedPageData]()
        
        // Instantiate the scraper on the MainActor
        let scraper = await StealthScraper(localWorkspaceRoots: localWorkspaceRoots)
        
        // 3. Crawl loop
        let pageBudget = min(max(maxPages, 0), 100)
        while pagesScraped < pageBudget {
            if let timeout = timeout {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed >= timeout {
                    throw SearchError.timeoutBudgetExceeded
                }
            }
            
            guard let nextURL = try await queueActor.dequeueNext(localWorkspaceRoots: localWorkspaceRoots) else {
                break // Queue empty or no crawlable URLs remaining
            }
            
            let urlString = nextURL.absoluteString
            let currentDepth = depthByURL[urlString] ?? 0
            
            do {
                // Scrape page on MainActor
                let scrapeResult = try await scraper.scrape(url: nextURL, configuration: scrapeConfig)
                
                // Compute MinHash signature of the text content
                let signature = MinHashDeduplicator.generateSignature(from: scrapeResult.text)
                
                // Check if page content is a duplicate of a previously crawled page
                let isDuplicate = try await queueActor.isDuplicate(signature: signature)
                if isDuplicate {
                    try await queueActor.markCompleted(urlString: urlString)
                    continue
                }
                
                // Save unique page to the crawl database
                try await queueActor.savePage(
                    urlString: urlString,
                    html: scrapeResult.html,
                    text: scrapeResult.text,
                    title: scrapeResult.title,
                    signature: signature
                )
                
                try await queueActor.markCompleted(urlString: urlString)
                pagesScraped += 1
                scrapedPagesData.append(ScrapedPageData(url: nextURL, text: scrapeResult.text))
                
                // Deep Research: Harvest relevant internal sub-links from markdown text
                if currentDepth < max(deepResearchDepth, 0) {
                    let harvestedURLs = Array(harvestURLs(from: scrapeResult.text, currentURL: nextURL).prefix(100))
                    if !harvestedURLs.isEmpty {
                        for harvestedURL in harvestedURLs {
                            if depthByURL[harvestedURL.absoluteString] == nil {
                                depthByURL[harvestedURL.absoluteString] = currentDepth + 1
                            }
                        }
                        // Enqueue sub-links with lower priority and set parent node
                        try await queueActor.enqueue(
                            urls: harvestedURLs,
                            priority: 5,
                            parentURLString: urlString,
                            localWorkspaceRoots: localWorkspaceRoots
                        )
                    }
                }
                
                // RAG: Extract the most semantically relevant text paragraphs for context
                let relevantContext = try await semanticCore.extractRelevantContext(
                    from: scrapeResult.text,
                    query: query,
                    maxCharacters: 3000
                )
                
                // Local LLM extraction
                let extractedData = try await semanticCore.extract(
                    from: relevantContext,
                    query: query,
                    as: T.self
                )
                
                if firstResult == nil {
                    firstResult = extractedData
                }
                
            } catch {
                var retryDelay: TimeInterval? = nil
                if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain {
                    if let response = nsError.userInfo["NSURLErrorFailingURLResponseErrorKey"] as? HTTPURLResponse {
                        if response.statusCode == 429 {
                            if let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After") {
                                retryDelay = TimeInterval(retryAfterHeader)
                            }
                        }
                    }
                }
                try await queueActor.markFailed(urlString: urlString, retryAfter: retryDelay)
                // Continue crawling other pages if one fails
            }
        }
        
        guard let data = firstResult else {
            throw SearchError.noResultsFound
        }
        
        // 4. Compile citations and nodes
        let citations = semanticCore.matchCitations(for: data, scrapedPages: scrapedPagesData)
        let queueNodes = try await queueActor.fetchAllNodes()
        let searchPathNodes = queueNodes.map { node in
            ResearchNode(
                urlString: node.urlString,
                status: node.status,
                priority: node.priority,
                parentURLString: node.parentURLString
            )
        }
        
        return ResearchOutput(data: data, citations: citations, searchPathNodes: searchPathNodes)
    }
    
    /// Parses absolute HTTP(S) sub-links from parsed markdown text.
    ///
    /// Social and community links are retained so a deep research run can follow
    /// public references to platforms such as Reddit, YouTube, GitHub, and Bilibili.
    internal func harvestURLs(from text: String, currentURL: URL) -> [URL] {
        let pattern = #"\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var urls = [URL]()
        var uniqueStrings = Set<String>()
        
        for match in matches {
            guard let urlRange = Range(match.range(at: 1), in: text) else { continue }
            let urlStr = String(text[urlRange])
            
            if let url = URL(string: urlStr), SearchURLPolicy.validate(url) {
                let absolute = url.absoluteString
                if !uniqueStrings.contains(absolute) {
                    uniqueStrings.insert(absolute)
                    urls.append(url)
                }
            }
        }
        return urls
    }
}

/// The structured response returned by research queries.
public struct ResearchOutput<T: ArchonGenerable & Codable & Sendable>: Sendable, Codable {
    public let data: T
    public let citations: [Citation]
    public let searchPathNodes: [ResearchNode]
    
    public init(data: T, citations: [Citation], searchPathNodes: [ResearchNode]) {
        self.data = data
        self.citations = citations
        self.searchPathNodes = searchPathNodes
    }
}

/// A node representation in the search visual mind-map graph.
public struct ResearchNode: Sendable, Codable, Hashable {
    public let urlString: String
    public let status: String
    public let priority: Int
    public let parentURLString: String?
    
    public init(urlString: String, status: String, priority: Int, parentURLString: String? = nil) {
        self.urlString = urlString
        self.status = status
        self.priority = priority
        self.parentURLString = parentURLString
    }
}

/// Structured diagnostic errors that can occur during crawling and information extraction.
public enum SearchError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    case localOnlyRequiresLocalSource
    case localOnlyRequiresStaticLocalCrawl
    case robotsDisallowed(urlString: String)
    case rateLimited(urlString: String, retryAfter: TimeInterval?)
    case extractionFailed(reason: String)
    case networkFailure(urlString: String, statusCode: Int)
    case initializationFailed(reason: String)
    case timeoutBudgetExceeded
    case noResultsFound
    
    public var description: String {
        switch self {
        case .localOnlyRequiresLocalSource:
            return "LocalOnlyRequiresLocalSource: A local-only search request must use an on-device corpus source."
        case .localOnlyRequiresStaticLocalCrawl:
            return "LocalOnlyRequiresStaticLocalCrawl: Local-only corpus search cannot use a WebKit crawl that may load external resources."
        case .robotsDisallowed(let urlString):
            return "RobotsDisallowed: Crawl disallowed by robots.txt for URL: \(urlString)"
        case .rateLimited(let urlString, let retryAfter):
            return "RateLimited: Request rate limited for URL: \(urlString). Retry-After: \(retryAfter ?? 0)s"
        case .extractionFailed(let reason):
            return "ExtractionFailed: Struct extraction failed. Reason: \(reason)"
        case .networkFailure(let urlString, let statusCode):
            return "NetworkFailure: HTTP \(statusCode) for URL: \(urlString)"
        case .initializationFailed(let reason):
            return "InitializationFailed: The crawl store could not be initialized. Reason: \(reason)"
        case .timeoutBudgetExceeded:
            return "TimeoutBudgetExceeded: Overall crawl timeout budget reached."
        case .noResultsFound:
            return "NoResultsFound: Failed to scrape or extract any structured data from the target sources."
        }
    }
}
