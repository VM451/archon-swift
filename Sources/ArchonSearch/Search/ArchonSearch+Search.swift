import Foundation

extension ArchonSearch {

    /// Searches public, indexed pages from one or more social/community platforms.
    ///
    /// This is a zero-key discovery surface. It does not provide authenticated API
    /// access, inject cookies, bypass robots or rate limits, or guarantee that a
    /// platform will allow the result page to be opened without login.
    public func searchSocialMedia(
        query: String,
        platforms: [SocialPlatform] = SocialPlatform.allCases,
        maxResults: Int = 10,
        maxSnippetCharacters: Int = 300,
        maxHighlights: Int = 3,
        livecrawl: LivecrawlPolicy = .fast,
        latency: TimeInterval? = nil
    ) async throws -> [SearchResult] {
        try await search(
            query: query,
            source: .socialMedia(platforms: platforms),
            maxResults: maxResults,
            maxSnippetCharacters: maxSnippetCharacters,
            maxHighlights: maxHighlights,
            livecrawl: livecrawl,
            latency: latency
        )
    }
    
    /// Real-time web search tool call returning webpage text and token-efficient highlights.
    ///
    /// - Parameters:
    ///   - query: The search query.
    ///   - source: Where to discover pages.
    ///   - maxResults: Maximum number of result pages to enrich.
    ///   - maxSnippetCharacters: Soft limit for the returned snippet text.
    ///   - maxHighlights: Number of top semantic highlights to return per result.
    ///   - livecrawl: How each result page is crawled (`fast` or `full`).
    ///   - latency: Optional total latency budget. Results collected before the budget is returned.
    /// - Returns: A list of ranked `SearchResult`s.
    public func search(
        query: String,
        source: DiscoverySource = .duckDuckGo,
        maxResults: Int = 10,
        maxSnippetCharacters: Int = 300,
        maxHighlights: Int = 3,
        livecrawl: LivecrawlPolicy = .fast,
        latency: TimeInterval? = nil
    ) async throws -> [SearchResult] {
        let startTime = Date()
        let urls = try await discoveryEngine.search(query: query, source: source)
        let targetURLs = Array(urls.prefix(maxResults))
        guard !targetURLs.isEmpty else { return [] }
        
        var results = Array<SearchResult?>(repeating: nil, count: targetURLs.count)
        let core = semanticCore
        let q = query
        
        switch livecrawl {
        case .fast:
            try await withThrowingTaskGroup(of: IndexedSearchResult?.self) { group in
                for (index, url) in targetURLs.enumerated() {
                    group.addTask {
                        do {
                            let (title, text, _) = try await HTMLContentExtractor.fetchStaticPage(url: url)
                            let snippet = try await core.extractRelevantContext(from: text, query: q, maxCharacters: maxSnippetCharacters)
                            let highlightContext = try await core.extractRelevantContext(from: text, query: q, maxCharacters: maxHighlights * 300)
                            let highlights = HTMLContentExtractor.highlights(from: highlightContext, maxHighlights: maxHighlights)
                            return IndexedSearchResult(index: index, result: SearchResult(url: url, title: title, snippet: snippet, highlights: highlights))
                        } catch {
                            return nil
                        }
                    }
                }
                for try await value in group {
                    if let value = value { results[value.index] = value.result }
                    if let latency = latency, Date().timeIntervalSince(startTime) >= latency {
                        break
                    }
                }
            }
        case .full(let scrapeConfig):
            let scraper = await StealthScraper()
            for (index, url) in targetURLs.enumerated() {
                if let latency = latency, Date().timeIntervalSince(startTime) >= latency { break }
                do {
                    let scrape = try await scraper.scrape(url: url, configuration: scrapeConfig)
                    let snippet = try await core.extractRelevantContext(from: scrape.text, query: q, maxCharacters: maxSnippetCharacters)
                    let highlightContext = try await core.extractRelevantContext(from: scrape.text, query: q, maxCharacters: maxHighlights * 300)
                    let highlights = HTMLContentExtractor.highlights(from: highlightContext, maxHighlights: maxHighlights)
                    results[index] = SearchResult(url: url, title: scrape.title, snippet: snippet, highlights: highlights)
                } catch {
                    // Skip failed full-rendered pages.
                }
            }
        }
        
        return results.compactMap { $0 }
    }
}

private struct IndexedSearchResult: Sendable {
    let index: Int
    let result: SearchResult
}
