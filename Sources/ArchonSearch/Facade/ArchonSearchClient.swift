import Foundation
import ArchonCore

/// High-level public facade for ArchonSearch 2.0.
/// Coordinates web meta-search, content extraction, grounding, and autonomous research.
public actor ArchonSearchClient: Sendable {
    public let configuration: ArchonSearchConfiguration
    private let searchEngine: any SearchEngine
    private let router: RetrievalRouter
    private let coordinator: ResearchCoordinator
    private let database: SearchDatabase?

    public init(
        configuration: ArchonSearchConfiguration = .onDevice(),
        database: SearchDatabase? = nil
    ) {
        self.configuration = configuration
        let searchURL = configuration.searchEngine.searxngURL
        let crawlerURL = configuration.crawler.crawl4aiURL

        if let searchURL {
            let primary = SearXNGClient(endpoint: searchURL)
            let fallback = DuckDuckGoSearchEngine()
            self.searchEngine = CompositeSearchEngine(primary: primary, fallback: fallback)
        } else {
            self.searchEngine = DuckDuckGoSearchEngine()
        }

        let cClient = crawlerURL.map { Crawl4AIClient(endpoint: $0) }
        let nReader = NativeReader(timeout: configuration.timeouts.fetchTimeout)
        let rRouter = RetrievalRouter(crawlClient: cClient, nativeReader: nReader)

        self.router = rRouter
        self.coordinator = ResearchCoordinator(searchEngine: self.searchEngine, retrievalRouter: rRouter)
        self.database = database
    }

    /// Searches the web via the configured on-device or companion search engine.
    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult] {
        try await searchEngine.search(query, categories: categories, page: page)
    }

    /// Ranked search: local rerank with freshness and host scoping.
    ///
    /// When `embedding` (or `options.embedding`) is enabled, the Apple-API
    /// embedding path blends a bounded semantic boost; otherwise behavior is
    /// keyword-identical to previous releases.
    public func rankedSearch(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1,
        options: SearchRankingOptions = SearchRankingOptions(),
        similarity: (any SemanticSimilarity)? = nil,
        semanticWeight: Double = 0.4,
        embedding: EmbeddingRerankOptions? = nil
    ) async throws -> [SearchResult] {
        let (results, _) = try await rankedSearchWithDiagnostics(
            query, categories: categories, page: page,
            options: options, similarity: similarity,
            semanticWeight: semanticWeight, embedding: embedding
        )
        return results
    }

    /// Ranked search with diagnostics, reporting `usedSemanticRerank`.
    public func rankedSearchWithDiagnostics(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1,
        options: SearchRankingOptions = SearchRankingOptions(),
        similarity: (any SemanticSimilarity)? = nil,
        semanticWeight: Double = 0.4,
        embedding: EmbeddingRerankOptions? = nil
    ) async throws -> (results: [SearchResult], diagnostics: SearchDiagnostics) {
        let start = Date()
        let results = try await searchEngine.search(query, categories: categories, page: page)
        let ranker = ResultReranker()
        let ranked: [SearchResult]
        let usedSemantic: Bool
        if embedding ?? options.embedding != nil {
            let out = ranker.rankWithEmbedding(
                results, for: query, options: options,
                embedding: embedding, similarity: similarity
            )
            ranked = out.results
            usedSemantic = out.usedSemanticRerank
        } else if let similarity {
            let out = ranker.rankWithSimilarity(
                results, for: query, options: options,
                similarity: similarity, semanticWeight: semanticWeight
            )
            ranked = out.results
            usedSemantic = out.usedSemanticRerank
        } else {
            ranked = ranker.rank(results, for: query, options: options)
            usedSemantic = false
        }
        var diagnostics = SearchDiagnostics(searchDuration: Date().timeIntervalSince(start))
        diagnostics.usedSemanticRerank = usedSemantic
        return (ranked, diagnostics)
    }

    /// Reads and extracts structured text and markdown from a webpage URL.
    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument {
        try await router.read(url: url, options: options)
    }

    /// Performs autonomous multi-round research on a given topic.
    public func research(topic: String, options: ResearchOptions = ResearchOptions()) async throws -> ResearchReport {
        try await coordinator.research(topic: topic, options: options)
    }

    /// Performs grounded web search and assembles prompt-injection-safe context with verified citations.
    public func ask(query: String) async throws -> (context: String, sources: [Source], citations: [Citation]) {
        let results = try await search(query, page: 1)
        var sources: [Source] = []

        for result in results.prefix(configuration.limits.maxResults) {
            do {
                let doc = try await read(url: result.url)
                let passage = SourcePassage(
                    sourceID: doc.id,
                    passageID: UUID(),
                    text: String(doc.text.prefix(800)),
                    score: 1.0
                )
                let source = Source(
                    id: doc.id,
                    url: doc.url,
                    title: doc.title.isEmpty ? result.title : doc.title,
                    passages: [passage]
                )
                sources.append(source)
            } catch {
                continue
            }
        }

        let builder = ContextBuilder(maxCharacters: 12_000)
        let context = builder.buildContext(from: sources)
        let graph = CitationGraph(sources: sources)
        let parsed = graph.parseCitations(from: context)
        let verified = graph.verify(citations: parsed).valid
        let citations = graph.resolve(citations: verified)

        return (context: context, sources: sources, citations: citations)
    }

    /// Performs grounded web search returning an answer with text, context, sources, and verified citations.
    @discardableResult
    public func ask(_ query: String) async throws -> SearchAnswer {
        let res = try await ask(query: query)
        return SearchAnswer(text: res.context, context: res.context, sources: res.sources, citations: res.citations)
    }

    /// Returns health check status across the search engine and Crawl4AI instances.
    public func checkHealth() async -> (searxngHealthy: Bool, crawlerHealthy: Bool) {
        let engineOk = await searchEngine.checkHealth()
        let routerHealth = await router.healthReport()
        return (searxngHealthy: engineOk, crawlerHealthy: routerHealth.isCrawlerAvailable)
    }
}

/// An answer containing grounded text and verified citations.
public struct SearchAnswer: Sendable {
    public let text: String
    public let context: String
    public let sources: [Source]
    public let citations: [Citation]

    public init(text: String, context: String, sources: [Source], citations: [Citation]) {
        self.text = text
        self.context = context
        self.sources = sources
        self.citations = citations
    }
}
