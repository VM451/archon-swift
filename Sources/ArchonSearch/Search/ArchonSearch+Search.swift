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
        let targetURLs = Array(urls.prefix(min(max(maxResults, 0), 100)))
        guard !targetURLs.isEmpty else { return [] }
        if let latency, latency <= Date().timeIntervalSince(startTime) {
            return []
        }
        let boundedSnippetCharacters = min(max(maxSnippetCharacters, 0), SearchURLPolicy.maxResponseBytes)
        let boundedHighlightCount = min(max(maxHighlights, 0), 100)
        
        var results = Array<SearchResult?>(repeating: nil, count: targetURLs.count)
        let core = semanticCore
        let q = query
        
        switch livecrawl {
        case .fast:
            try await withThrowingTaskGroup(of: IndexedSearchEvent.self) { group in
                for (index, url) in targetURLs.enumerated() {
                    group.addTask {
                        do {
                            let (title, text, _) = try await HTMLContentExtractor.fetchStaticPage(url: url)
                            let snippet = try await core.extractRelevantContext(from: text, query: q, maxCharacters: boundedSnippetCharacters)
                            let highlightContext = try await core.extractRelevantContext(from: text, query: q, maxCharacters: boundedHighlightCount * 300)
                            let highlights = HTMLContentExtractor.highlights(from: highlightContext, maxHighlights: boundedHighlightCount)
                            return .completed(IndexedSearchResult(index: index, result: SearchResult(url: url, title: title, snippet: snippet, highlights: highlights)))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return .completed(nil)
                        }
                    }
                }
                if let latency {
                    let remaining = max(0, latency - Date().timeIntervalSince(startTime))
                    group.addTask {
                        do {
                            try await Task.sleep(for: .seconds(remaining))
                            return .deadline
                        } catch {
                            return .completed(nil)
                        }
                    }
                }
                var completedPages = 0
                while let event = try await group.next() {
                    switch event {
                    case .completed(let value):
                        completedPages += 1
                        if let value { results[value.index] = value.result }
                        if completedPages == targetURLs.count {
                            group.cancelAll()
                            return
                        }
                    case .deadline:
                        group.cancelAll()
                        return
                    }
                }
            }
        case .full(let scrapeConfig):
            let scraper = await StealthScraper()
            for (index, url) in targetURLs.enumerated() {
                if let latency = latency, Date().timeIntervalSince(startTime) >= latency { break }
                do {
                    let scrape = try await scraper.scrape(url: url, configuration: scrapeConfig)
                    let snippet = try await core.extractRelevantContext(from: scrape.text, query: q, maxCharacters: boundedSnippetCharacters)
                    let highlightContext = try await core.extractRelevantContext(from: scrape.text, query: q, maxCharacters: boundedHighlightCount * 300)
                    let highlights = HTMLContentExtractor.highlights(from: highlightContext, maxHighlights: boundedHighlightCount)
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

private enum IndexedSearchEvent: Sendable {
    case completed(IndexedSearchResult?)
    case deadline
}
