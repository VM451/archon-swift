import Foundation
import ArchonCore

/// Actor coordinating bounded autonomous multi-round research workflows.
public actor ResearchCoordinator: Sendable {
    public let searchEngine: any SearchEngine
    public let retrievalRouter: RetrievalRouter
    public let options: ResearchOptions

    public init(
        searchEngine: any SearchEngine,
        retrievalRouter: RetrievalRouter,
        options: ResearchOptions = ResearchOptions()
    ) {
        self.searchEngine = searchEngine
        self.retrievalRouter = retrievalRouter
        self.options = options
    }

    public init(
        searxngClient: SearXNGClient,
        retrievalRouter: RetrievalRouter,
        options: ResearchOptions = ResearchOptions()
    ) {
        self.init(searchEngine: searxngClient, retrievalRouter: retrievalRouter, options: options)
    }

    public init(
        searchClient: SearXNGClient,
        router: RetrievalRouter,
        options: ResearchOptions = ResearchOptions()
    ) {
        self.init(searchEngine: searchClient, retrievalRouter: router, options: options)
    }

    /// Executes the full autonomous research pipeline for the given topic.
    public func research(topic: String, options: ResearchOptions? = nil) async throws -> ResearchReport {
        let opts = options ?? self.options
        let startTime = Date()
        var diagnostics = SearchDiagnostics()
        var collectedSources: [Source] = []
        var visitedURLs = Set<URL>()
        var pendingQueries = [topic, "\(topic) overview", "\(topic) analysis", "\(topic) latest"]

        for round in 1...opts.maxRounds {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startTime) >= opts.timeout { break }
            guard !pendingQueries.isEmpty, collectedSources.count < opts.maxDocuments else { break }

            let currentQueries = Array(pendingQueries.prefix(opts.queriesPerRound))
            pendingQueries.removeFirst(min(pendingQueries.count, opts.queriesPerRound))

            var foundResults: [SearchResult] = []
            for query in currentQueries {
                do {
                    let results = try await searchEngine.search(query, categories: nil, page: 1)
                    diagnostics.engineResults[query] = results.count
                    foundResults.append(contentsOf: results)
                } catch {
                    diagnostics.recordError(error)
                }
            }

            let unvisited = foundResults.filter { visitedURLs.insert($0.url).inserted }
            let remainingBudget = opts.maxDocuments - collectedSources.count
            let toFetch = Array(unvisited.prefix(remainingBudget))

            for result in toFetch {
                try Task.checkCancellation()
                do {
                    diagnostics.recordFetch()
                    let doc = try await retrievalRouter.read(url: result.url)
                    let passages = extractPassages(from: doc)
                    let source = Source(url: doc.url, title: doc.title, passages: passages)
                    collectedSources.append(source)
                } catch {
                    diagnostics.recordError(error)
                }
            }

            if round < opts.maxRounds && collectedSources.count < opts.maxDocuments {
                pendingQueries.append("\(topic) details round \(round + 1)")
            }
        }

        diagnostics.searchDuration = Date().timeIntervalSince(startTime)
        return synthesizeReport(topic: topic, sources: collectedSources, diagnostics: diagnostics)
    }

    private func extractPassages(from document: WebDocument) -> [SourcePassage] {
        let text = document.markdown.isEmpty ? document.text : document.markdown
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 40 }
        let sourceID = UUID()
        return Array(paragraphs.prefix(5)).enumerated().map { index, p in
            SourcePassage(sourceID: sourceID, text: p, score: 1.0 - (Double(index) * 0.1))
        }
    }

    private func synthesizeReport(topic: String, sources: [Source], diagnostics: SearchDiagnostics) -> ResearchReport {
        var citationGraph = CitationGraph()
        for (idx, source) in sources.enumerated() {
            citationGraph.register(source: source, index: idx + 1)
        }

        var summaryLines: [String] = []
        var sections: [ResearchReport.Section] = []

        for (idx, source) in sources.enumerated() {
            let tag = CitationGraph.tag(sourceIndex: idx + 1, passageIndex: 1)
            let snippet = source.passages.first?.text.prefix(180) ?? ""
            let content = "\(snippet) [S\(idx + 1)]"
            sections.append(ResearchReport.Section(heading: source.title, content: content))
            summaryLines.append("- \(source.title): \(tag)")
        }

        let summary = summaryLines.isEmpty ? "No sources retrieved." : summaryLines.joined(separator: "\n")
        let parsed = citationGraph.parseCitations(from: sections.map(\.content).joined(separator: " "))
        let verified = citationGraph.resolve(citations: citationGraph.verify(citations: parsed).valid)

        return ResearchReport(
            query: topic,
            summary: summary,
            sections: sections,
            sources: sources,
            citations: verified,
            diagnostics: diagnostics
        )
    }
}
