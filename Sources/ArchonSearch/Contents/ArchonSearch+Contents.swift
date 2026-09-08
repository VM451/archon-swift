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
        if let timeout, timeout <= Date().timeIntervalSince(startTime) {
            return []
        }
        let boundedHighlightCount = min(max(maxHighlights, 0), 100)
        let boundedHighlightCharacters = min(max(maxHighlightCharacters, 0), SearchURLPolicy.maxResponseBytes)
        var results = Array<ContentsResult?>(repeating: nil, count: targetURLs.count)
        let core = semanticCore
        
        switch livecrawl {
        case .fast:
            // Two-stage extraction: static URLSession fetch first; pages whose
            // static HTML yields too little article text escalate to a rendered
            // WebKit scrape before giving up. The scraper is shared so at most
            // one WebKit instance exists per escalation.
            let scraper = await StealthScraper(localWorkspaceRoots: localWorkspaceRoots)
            let extractor = HeuristicArticleExtractor()
            try await withThrowingTaskGroup(of: IndexedContentsEvent.self) { group in
                for (index, url) in targetURLs.enumerated() {
                    group.addTask {
                        do {
                            let (title, text, html) = try await HTMLContentExtractor.fetchStaticPage(url: url)
                            let article = await Self.resolveArticle(
                                url: url,
                                staticTitle: title,
                                staticText: text,
                                staticHTML: html,
                                extractor: extractor,
                                scraper: scraper
                            )
                            let highlights = try await core.extractRelevantContext(from: article.text, query: query, maxCharacters: boundedHighlightCharacters)
                            return .completed(IndexedContentsResult(index: index, result: ContentsResult(
                                url: url,
                                title: article.title.isEmpty ? title : article.title,
                                markdown: article.text,
                                html: html,
                                highlights: HTMLContentExtractor.highlights(from: highlights, maxHighlights: boundedHighlightCount)
                            )))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return .completed(nil)
                        }
                    }
                }
                if let timeout {
                    let remaining = max(0, timeout - Date().timeIntervalSince(startTime))
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
            let scraper = await StealthScraper(localWorkspaceRoots: localWorkspaceRoots)
            for (index, url) in targetURLs.enumerated() {
                if let timeout = timeout, Date().timeIntervalSince(startTime) >= timeout { break }
                do {
                    let scrape = try await scraper.scrape(url: url, configuration: scrapeConfig)
                    let highlights = try await core.extractRelevantContext(from: scrape.text, query: query, maxCharacters: boundedHighlightCharacters)
                    results[index] = ContentsResult(
                        url: url,
                        title: scrape.title,
                        markdown: scrape.text,
                        html: scrape.html,
                        highlights: HTMLContentExtractor.highlights(from: highlights, maxHighlights: boundedHighlightCount)
                    )
                } catch {
                    // Skip failed full-rendered pages.
                }
            }
        }
        
        return results.compactMap { $0 }
    }

    /// Two-stage article resolution: prefer the static-fetch extraction and
    /// escalate to a rendered scrape only when the static body is thin.
    /// Never throws: when rendering also fails, the legacy plain-text result
    /// is preserved so previously succeeding pages keep succeeding.
    private static func resolveArticle(
        url: URL,
        staticTitle: String,
        staticText: String,
        staticHTML: String,
        extractor: HeuristicArticleExtractor,
        scraper: StealthScraper
    ) async -> CleanArticle {
        if let article = extractor.extractArticle(from: staticHTML, url: url),
           article.text.count >= CleanArticle.minimumBodyCharacters {
            return article
        }
        do {
            try Task.checkCancellation()
            let scrape = try await scraper.scrape(url: url, configuration: ScrapeConfiguration())
            if let rendered = extractor.extractArticle(from: scrape.html, url: url),
               !rendered.text.isEmpty {
                return CleanArticle(
                    url: url,
                    title: rendered.title.isEmpty ? scrape.title : rendered.title,
                    author: rendered.author,
                    publishedAt: rendered.publishedAt,
                    text: rendered.text,
                    headings: rendered.headings,
                    method: .escalatedRender
                )
            }
        } catch {
            // Fall through to the static result below.
        }
        if let article = extractor.extractArticle(from: staticHTML, url: url) {
            return article
        }
        return CleanArticle(url: url, title: staticTitle, text: staticText, method: .staticFetch)
    }
}

private struct IndexedContentsResult: Sendable {
    let index: Int
    let result: ContentsResult
}

private enum IndexedContentsEvent: Sendable {
    case completed(IndexedContentsResult?)
    case deadline
}
