import Foundation

extension ArchonSearch {
    
    /// Multi-step deep research run optimized for complex queries.
    ///
    /// Runs the original query plus any `subQueries` as a sequence of research passes,
    /// each with its own fresh crawl context. The final answer comes from the original query,
    /// enriched by the sub-query evidence.
    public func deepSearch<T: ArchonGenerable & Codable & Sendable>(
        query: String,
        subQueries: [String] = [],
        extracting type: T.Type,
        maxPagesPerStep: Int = 3,
        source: DiscoverySource = .duckDuckGo,
        scrapeConfig: ScrapeConfiguration = ScrapeConfiguration(),
        timeout: TimeInterval? = nil
    ) async throws -> DeepSearchOutput<T> {
        let startTime = Date()
        let allQueries = [query] + subQueries
        var steps = [DeepResearchStep<T>]()
        var allCitations = [Citation]()
        var allNodes = [ResearchNode]()
        
        for (index, subQuery) in allQueries.enumerated() {
            if let timeout = timeout, Date().timeIntervalSince(startTime) >= timeout { break }
            let remaining = timeout.map { max(0, startTime.addingTimeInterval($0).timeIntervalSinceNow) }
            let stepEngine = ArchonSearch(structuredExtractionHandler: structuredExtractionHandler)
            let output = try await stepEngine.research(
                query: subQuery,
                extracting: type,
                maxPages: maxPagesPerStep,
                source: source,
                scrapeConfig: scrapeConfig,
                deepResearchDepth: 2,
                timeout: remaining
            )
            steps.append(DeepResearchStep(iteration: index, subQuery: subQuery, output: output))
            allCitations.append(contentsOf: output.citations)
            allNodes.append(contentsOf: output.searchPathNodes)
        }
        
        guard let firstStep = steps.first else {
            throw SearchError.noResultsFound
        }
        
        let uniqueCitations = Array(Set(allCitations)).sorted { $0.index < $1.index }
        let uniqueNodes = Array(Set(allNodes))
        
        return DeepSearchOutput(
            originalQuery: query,
            finalAnswer: firstStep.output.data,
            steps: steps,
            allCitations: uniqueCitations,
            allSearchPathNodes: uniqueNodes
        )
    }
}
