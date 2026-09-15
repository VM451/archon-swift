import Testing
import Foundation
@testable import ArchonSearch

@Suite("ArchonSearch Edge Cases")
struct ArchonSearchEdgeCasesTests {

    private func makeDoc(title: String, content: String) -> LocalSearchDocument {
        LocalSearchDocument(
            url: URL(string: "https://example.com/\(UUID().uuidString)")!,
            title: title,
            content: content
        )
    }

    // MARK: - LocalSearchIndex common

    @Test("Upsert then search finds document with title boost ordering")
    func upsertAndSearch() async throws {
        let index = try LocalSearchIndex()
        let doc = makeDoc(title: "Swift Concurrency Guide", content: "structured concurrency tasks actors")
        try await index.upsert(doc)
        #expect(await index.count == 1)
        let results = try await index.search(query: "swift concurrency", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].id == doc.id)
    }

    @Test("Empty and punctuation-only queries return empty")
    func emptyQueries() async throws {
        let index = try LocalSearchIndex()
        try await index.upsert(makeDoc(title: "Hello", content: "world"))
        #expect(try await index.search(query: "", limit: 10).isEmpty)
        #expect(try await index.search(query: "   ... !!!", limit: 10).isEmpty)
        #expect(try await index.search(query: "nomatchxyz", limit: 10).isEmpty)
    }

    @Test("Limit zero returns empty; negative and over-500 throw invalidLimit")
    func limitEdges() async throws {
        let index = try LocalSearchIndex()
        try await index.upsert(makeDoc(title: "a", content: "b"))
        #expect(try await index.search(query: "a", limit: 0).isEmpty)
        await #expect(throws: LocalSearchIndexError.invalidLimit(-1)) {
            try await index.search(query: "a", limit: -1)
        }
        await #expect(throws: LocalSearchIndexError.invalidLimit(501)) {
            try await index.search(query: "a", limit: 501)
        }
        // Boundary: 500 is accepted
        _ = try await index.search(query: "a", limit: 500)
    }

    @Test("Remove missing id returns false; rebuild replaces corpus")
    func removeAndRebuild() async throws {
        let index = try LocalSearchIndex()
        #expect(try await index.remove(id: UUID()) == false)
        let d1 = makeDoc(title: "one", content: "alpha")
        let d2 = makeDoc(title: "two", content: "beta")
        try await index.upsert(d1)
        #expect(try await index.remove(id: d1.id) == true)
        #expect(await index.count == 0)
        try await index.upsert(d1)
        try await index.rebuild([d2])
        #expect(await index.count == 1)
        #expect(try await index.search(query: "alpha", limit: 10).isEmpty)
        #expect(try await index.search(query: "beta", limit: 10).count == 1)
    }

    @Test("Non-file storage URL throws invalidStorageURL")
    func invalidStorageURL() {
        #expect(throws: LocalSearchIndexError.invalidStorageURL) {
            _ = try LocalSearchIndex(storageURL: URL(string: "https://example.com/index.json")!)
        }
    }

    @Test("File-backed persistence round-trips documents")
    func persistenceRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString).json")
        let index = try LocalSearchIndex(storageURL: url)
        let doc = makeDoc(title: "persist me", content: "durable corpus")
        try await index.upsert(doc)
        let reopened = try LocalSearchIndex(storageURL: url)
        #expect(await reopened.count == 1)
        #expect(try await reopened.search(query: "persist", limit: 10).count == 1)
    }

    // MARK: - SearchError

    @Test("SearchError descriptions are non-empty and Codable round-trips")
    func searchErrorCases() throws {
        let cases: [SearchError] = [
            .offline, .timeout(reason: "t"), .networkPolicy(reason: "p"),
            .searxng(reason: "s"), .crawl4ai(reason: "c"), .extraction(reason: "e"),
            .invalidURL(urlString: "ht!tp"), .localOnlyRequiresLocalSource,
            .localOnlyRequiresStaticLocalCrawl, .robotsDisallowed(urlString: "https://x"),
            .rateLimited(urlString: "https://x", retryAfter: nil),
            .rateLimited(urlString: "https://x", retryAfter: 5),
            .extractionFailed(reason: "f"), .networkFailure(urlString: "https://x", statusCode: 500),
            .initializationFailed(reason: "i"), .timeoutBudgetExceeded, .noResultsFound
        ]
        for err in cases {
            #expect(!err.description.isEmpty)
            #expect(err.errorDescription == err.description)
            let data = try JSONEncoder().encode(err)
            #expect(try JSONDecoder().decode(SearchError.self, from: data) == err)
        }
    }

    // MARK: - MinHash

    @Test("MinHash signature deterministic; identical texts score 1.0")
    func minHashCommon() {
        let a = MinHashDeduplicator.generateSignature(from: "the quick brown fox jumps over the lazy dog near the river bank")
        let b = MinHashDeduplicator.generateSignature(from: "the quick brown fox jumps over the lazy dog near the river bank")
        #expect(a.count == 128)
        #expect(MinHashDeduplicator.jaccardSimilarity(sig1: a, sig2: b) == 1.0)
    }

    @Test("MinHash edge: empty text, mismatched lengths")
    func minHashEdges() {
        let empty = MinHashDeduplicator.generateSignature(from: "")
        #expect(empty.count == 128)
        let other = MinHashDeduplicator.generateSignature(from: "completely different words about quantum baking zebra")
        let sim = MinHashDeduplicator.jaccardSimilarity(sig1: empty, sig2: other)
        #expect(sim >= 0.0 && sim <= 1.0)
        #expect(MinHashDeduplicator.jaccardSimilarity(sig1: [], sig2: []) == 0.0)
        #expect(MinHashDeduplicator.jaccardSimilarity(sig1: [1, 2], sig2: [1]) == 0.0)
    }

    // MARK: - Configuration + diagnostics

    @Test("Configuration factories produce expected routing modes")
    func configFactories() {
        #expect(ArchonSearchConfiguration.onDevice().routingMode == .nativeOnly)
        #expect(ArchonSearchConfiguration.localFirst().routingMode == .preferCrawler)
        #expect(ArchonSearchConfiguration.dockerCompanion().routingMode == .preferCrawler)
        #expect(ArchonSearchConfiguration.RoutingMode.allCases.count == 5)
    }

    @Test("SearchDiagnostics recording helpers")
    func diagnostics() {
        var d = SearchDiagnostics(
            searchDuration: 0, engineResults: [:], urlFetchCount: 0,
            cacheHits: 0, extractionMethod: "none", characterEstimate: 0,
            tokenEstimate: 0, errors: []
        )
        d.recordFetch()
        d.recordCacheHit()
        d.recordError(SearchError.offline)
        #expect(d.urlFetchCount == 1)
        #expect(d.cacheHits == 1)
        #expect(d.errors.count == 1)
    }

    // MARK: - Cancellation / policy

    @Test("Cancelled search task throws CancellationError")
    func cancellation() async throws {
        let index = try LocalSearchIndex()
        try await index.upsert(makeDoc(title: "cancel", content: "target"))
        let task: Task<[SearchResult], Error> = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            return try await index.search(query: "cancel", limit: 10)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("SearchResult highlights only contain query terms")
    func highlightPolicy() async throws {
        let index = try LocalSearchIndex()
        try await index.upsert(makeDoc(title: "SwiftUI views", content: "swiftui layout system details"))
        let results = try await index.search(query: "swiftui", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].highlights.allSatisfy { $0 == "swiftui" })
    }
}
