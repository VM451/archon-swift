import Foundation

/// Deterministic local reranker (SEARCH-002: Tavily/Exa answer).
///
/// Combines engine score, query-term overlap across title/snippet, and an
/// exponential freshness decay. Undated results keep relevance order; dated
/// results gain a bounded recency boost. Sorting is stable by URL slug.
public struct ResultReranker: Sendable {
    public init() {}

    public func rank(
        _ results: [SearchResult],
        for query: String,
        options: SearchRankingOptions = SearchRankingOptions(),
        now: Date = Date()
    ) -> [SearchResult] {
        rank(results, for: query, options: options, similarity: nil, semanticWeight: 0, now: now)
    }

    /// Semantic-aware overload. When `similarity` is provided, each result
    /// gains a bounded meaning-overlap boost (`semanticWeight`, clamped to
    /// 0...1). A `nil` similarity or per-pair `nil` keeps keyword behavior.
    public func rank(
        _ results: [SearchResult],
        for query: String,
        options: SearchRankingOptions = SearchRankingOptions(),
        similarity: (any SemanticSimilarity)?,
        semanticWeight: Double = 0.4,
        now: Date = Date()
    ) -> [SearchResult] {
        let terms = tokenize(query)
        let weight = min(max(semanticWeight, 0), 1)
        var scored: [(result: SearchResult, score: Double)] = []
        scored.reserveCapacity(results.count)
        for result in results {
            guard passesScope(result, options: options) else { continue }
            guard passesFreshness(result, options: options, now: now) else { continue }
            let base = result.score ?? 0.5
            let overlap = termOverlap(terms: terms, result: result)
            var score = base + (overlap * 0.5)
            if result.title.lowercased().contains(terms.first ?? "") && !(terms.first ?? "").isEmpty {
                score += 0.05
            }
            if options.preferRecent, let date = result.publishedAt {
                let age = max(0, now.timeIntervalSince(date))
                let halfLife = max(1, options.freshnessHalfLife)
                score += 0.3 * exp(-age / halfLife)
            }
            if weight > 0, let similarity,
               let semantic = similarity.similarity(between: query, and: result.title + " " + result.snippet) {
                score += min(max(semantic, 0), 1) * weight
            }
            scored.append((result, score))
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.result.url.absoluteString < $1.result.url.absoluteString
            }
            .prefix(max(0, options.maxResults))
            .map(\.result)
    }

    private func passesScope(_ result: SearchResult, options: SearchRankingOptions) -> Bool {
        guard let host = result.url.host?.lowercased() else { return true }
        if !options.allowHosts.isEmpty {
            let allowed = options.allowHosts.contains { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }
            guard allowed else { return false }
        }
        return !options.blockHosts.contains { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }
    }

    private func passesFreshness(_ result: SearchResult, options: SearchRankingOptions, now: Date) -> Bool {
        guard let maxAge = options.maxAge, let date = result.publishedAt else { return true }
        return now.timeIntervalSince(date) <= maxAge
    }

    private func termOverlap(terms: [String], result: SearchResult) -> Double {
        guard !terms.isEmpty else { return 0 }
        let haystack = (result.title + " " + result.snippet).lowercased()
        let hits = terms.filter { haystack.contains($0) }.count
        return Double(hits) / Double(terms.count)
    }

    private func tokenize(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}
