import Foundation

extension ArchonSearch {
    
    /// Asynchronous agent workflow that builds a list of structured items from multiple pages.
    ///
    /// Useful for list-building, enrichment, and lead/research collection.
    public func buildList<T: ArchonGenerable & Codable & Sendable>(
        query: String,
        itemType: T.Type,
        targetCount: Int = 5,
        maxPages: Int = 10,
        source: DiscoverySource = .duckDuckGo,
        scrapeConfig: ScrapeConfiguration = ScrapeConfiguration(),
        timeout: TimeInterval? = nil
    ) async throws -> ListBuildingOutput<T> {
        let startTime = Date()
        let seedURLs = try await discoveryEngine.search(query: query, source: source)
        guard !seedURLs.isEmpty else { throw SearchError.noResultsFound }
        try await queueActor.enqueue(urls: seedURLs, priority: 10, parentURLString: nil)
        
        let scraper = await StealthScraper()
        var items = [T]()
        var citations = [Citation]()
        var pagesScraped = 0
        
        while pagesScraped < maxPages && items.count < targetCount {
            if let timeout = timeout, Date().timeIntervalSince(startTime) >= timeout {
                throw SearchError.timeoutBudgetExceeded
            }
            
            guard let nextURL = try await queueActor.dequeueNext() else { break }
            let urlString = nextURL.absoluteString
            
            do {
                let scrape = try await scraper.scrape(url: nextURL, configuration: scrapeConfig)
                let signature = MinHashDeduplicator.generateSignature(from: scrape.text)
                let isDuplicate = try await queueActor.isDuplicate(signature: signature)
                if isDuplicate {
                    try await queueActor.markCompleted(urlString: urlString)
                    continue
                }
                
                try await queueActor.savePage(
                    urlString: urlString,
                    html: scrape.html,
                    text: scrape.text,
                    title: scrape.title,
                    signature: signature
                )
                try await queueActor.markCompleted(urlString: urlString)
                pagesScraped += 1
                
                let context = try await semanticCore.extractRelevantContext(from: scrape.text, query: query, maxCharacters: 3000)
                let extracted = try await semanticCore.extract(from: context, query: query, as: T.self)
                items.append(extracted)
                
                let pageData = ScrapedPageData(url: nextURL, text: scrape.text)
                let pageCitations = semanticCore.matchCitations(for: extracted, scrapedPages: [pageData])
                citations.append(contentsOf: pageCitations)
            } catch {
                try? await queueActor.markFailed(urlString: urlString)
            }
        }
        
        guard !items.isEmpty else { throw SearchError.noResultsFound }
        
        let renumbered = citations.enumerated().map { index, citation in
            Citation(index: index + 1, sourceURLString: citation.sourceURLString, snippet: citation.snippet)
        }
        
        return ListBuildingOutput(query: query, items: items, citations: renumbered)
    }
}
