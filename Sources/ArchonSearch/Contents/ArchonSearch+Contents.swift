import Foundation

extension ArchonSearch {
    
    /// Discover pages and return full-page contents with AI-optimized highlights.
    public func contents(
        query: String,
        source: DiscoverySource = .duckDuckGo,
        maxPages: Int = 3,
        livecrawl: LivecrawlPolicy = .full(scrapeConfig: ScrapeConfiguration()),
        maxHighlights: Int = 5,
        maxHighlightCharacters: Int = 1000,
        timeout: TimeInterval? = nil
    ) async throws -> [ContentsResult] {
        let startTime = Date()
        let urls = try await discoveryEngine.search(query: query, source: source)
        let targetURLs = Array(urls.prefix(min(max(maxPages, 0), 100)))
        return try await contents(
            for: targetURLs,
            query: query,
            livecrawl: livecrawl,
            maxHighlights: maxHighlights,
            maxHighlightCharacters: maxHighlightCharacters,
            timeout: timeout,
            startTime: startTime
        )
    }
    
    /// Return full-page contents for a specific set of URLs.
    public func contents(
        for urls: [URL],
        query: String,
        livecrawl: LivecrawlPolicy = .full(scrapeConfig: ScrapeConfiguration()),
        maxHighlights: Int = 5,
        maxHighlightCharacters: Int = 1000,
        timeout: TimeInterval? = nil
    ) async throws -> [ContentsResult] {
        return try await contents(
            for: urls,
            query: query,
            livecrawl: livecrawl,
            maxHighlights: maxHighlights,
            maxHighlightCharacters: maxHighlightCharacters,
            timeout: timeout,
            startTime: Date()
        )
    }
    
    private func contents(
        for urls: [URL],
        query: String,
        livecrawl: LivecrawlPolicy,
        maxHighlights: Int,
        maxHighlightCharacters: Int,
        timeout: TimeInterval?,
        startTime: Date
    ) async throws -> [ContentsResult] {
        let targetURLs = urls
        var results = Array<ContentsResult?>(repeating: nil, count: targetURLs.count)
        let core = semanticCore
        
        switch livecrawl {
        case .fast:
            try await withThrowingTaskGroup(of: IndexedContentsResult?.self) { group in
                for (index, url) in targetURLs.enumerated() {
                    group.addTask {
                        do {
                            let (title, text, html) = try await HTMLContentExtractor.fetchStaticPage(url: url)
                            let highlights = try await core.extractRelevantContext(from: text, query: query, maxCharacters: maxHighlightCharacters)
                            return IndexedContentsResult(index: index, result: ContentsResult(
                                url: url,
                                title: title,
                                markdown: text,
                                html: html,
                                highlights: HTMLContentExtractor.highlights(from: highlights, maxHighlights: maxHighlights)
                            ))
                        } catch {
                            return nil
                        }
                    }
                }
                for try await value in group {
                    if let value = value { results[value.index] = value.result }
                    if let timeout = timeout, Date().timeIntervalSince(startTime) >= timeout {
                        break
                    }
                }
            }
        case .full(let scrapeConfig):
            let scraper = await StealthScraper()
            for (index, url) in targetURLs.enumerated() {
                if let timeout = timeout, Date().timeIntervalSince(startTime) >= timeout { break }
                do {
                    let scrape = try await scraper.scrape(url: url, configuration: scrapeConfig)
                    let highlights = try await core.extractRelevantContext(from: scrape.text, query: query, maxCharacters: maxHighlightCharacters)
                    results[index] = ContentsResult(
                        url: url,
                        title: scrape.title,
                        markdown: scrape.text,
                        html: scrape.html,
                        highlights: HTMLContentExtractor.highlights(from: highlights, maxHighlights: maxHighlights)
                    )
                } catch {
                    // Skip failed full-rendered pages.
                }
            }
        }
        
        return results.compactMap { $0 }
    }
}

private struct IndexedContentsResult: Sendable {
    let index: Int
    let result: ContentsResult
}
