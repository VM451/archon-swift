import Foundation
import SwiftData

extension ArchonSearch {
    /// Runs an autonomous, stealth, on-device search and structured information extraction.
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
        let seedURLs = try await discoveryEngine.search(query: query, source: source)
        try await queueActor.enqueue(urls: seedURLs, priority: 10, parentURLString: nil, localWorkspaceRoots: localWorkspaceRoots)
        
        var depthByURL = [String: Int]()
        for seedURL in seedURLs { depthByURL[seedURL.absoluteString] = 0 }
        
        var firstResult: T?
        var pagesScraped = 0
        var scrapedPagesData = [ScrapedPageData]()
        let scraper = await StealthScraper(localWorkspaceRoots: localWorkspaceRoots)
        let pageBudget = min(max(maxPages, 0), 100)

        while pagesScraped < pageBudget {
            if let timeout, Date().timeIntervalSince(startTime) >= timeout {
                throw SearchError.timeoutBudgetExceeded
            }
            guard let nextURL = try await queueActor.dequeueNext(localWorkspaceRoots: localWorkspaceRoots) else {
                break
            }
            let urlString = nextURL.absoluteString
            let currentDepth = depthByURL[urlString] ?? 0
            
            do {
                let scrapeResult = try await scraper.scrape(url: nextURL, configuration: scrapeConfig)
                let signature = MinHashDeduplicator.generateSignature(from: scrapeResult.text)
                if try await queueActor.isDuplicate(signature: signature) {
                    try await queueActor.markCompleted(urlString: urlString)
                    continue
                }
                
                try await queueActor.savePage(urlString: urlString, html: scrapeResult.html, text: scrapeResult.text, title: scrapeResult.title, signature: signature)
                try await queueActor.markCompleted(urlString: urlString)
                pagesScraped += 1
                scrapedPagesData.append(ScrapedPageData(url: nextURL, text: scrapeResult.text))
                
                if currentDepth < max(deepResearchDepth, 0) {
                    let harvestedURLs = Array(harvestURLs(from: scrapeResult.text, currentURL: nextURL).prefix(100))
                    for harvestedURL in harvestedURLs where depthByURL[harvestedURL.absoluteString] == nil {
                        depthByURL[harvestedURL.absoluteString] = currentDepth + 1
                    }
                    try await queueActor.enqueue(urls: harvestedURLs, priority: 5, parentURLString: urlString, localWorkspaceRoots: localWorkspaceRoots)
                }
                
                let relevantContext = try await semanticCore.extractRelevantContext(from: scrapeResult.text, query: query, maxCharacters: 3000)
                let extractedData = try await semanticCore.extract(from: relevantContext, query: query, as: T.self)
                if firstResult == nil { firstResult = extractedData }
            } catch {
                var retryDelay: TimeInterval? = nil
                if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain,
                   let response = nsError.userInfo["NSURLErrorFailingURLResponseErrorKey"] as? HTTPURLResponse,
                   response.statusCode == 429, let retryHeader = response.value(forHTTPHeaderField: "Retry-After") {
                    retryDelay = TimeInterval(retryHeader)
                }
                try await queueActor.markFailed(urlString: urlString, retryAfter: retryDelay)
            }
        }
        
        guard let data = firstResult else { throw SearchError.noResultsFound }
        let citations = semanticCore.matchCitations(for: data, scrapedPages: scrapedPagesData)
        let queueNodes = try await queueActor.fetchAllNodes()
        let searchPathNodes = queueNodes.map { ResearchNode(urlString: $0.urlString, status: $0.status, priority: $0.priority, parentURLString: $0.parentURLString) }
        return ResearchOutput(data: data, citations: citations, searchPathNodes: searchPathNodes)
    }

    internal func harvestURLs(from text: String, currentURL: URL) -> [URL] {
        let pattern = #"\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var urls = [URL]()
        var uniqueStrings = Set<String>()
        for match in matches {
            guard let urlRange = Range(match.range(at: 1), in: text) else { continue }
            let urlStr = String(text[urlRange])
            if let url = URL(string: urlStr), SearchURLPolicy.validate(url), !uniqueStrings.contains(url.absoluteString) {
                uniqueStrings.insert(url.absoluteString)
                urls.append(url)
            }
        }
        return urls
    }
}
