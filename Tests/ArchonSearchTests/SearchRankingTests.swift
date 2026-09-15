import Testing
import Foundation
@testable import ArchonSearch

@Suite("Ranking Registry Rewriter")
struct RankingRegistryRewriterTests {
    private func result(title: String, host: String, daysOld: Double?, score: Double?) -> SearchResult {
        SearchResult(
            title: title,
            url: URL(string: "https://\(host)/a")!,
            snippet: title,
            publishedAt: daysOld.map { Date().addingTimeInterval(-$0 * 86_400) },
            score: score
        )
    }

    @Test("Rerank prefers term overlap then freshness, deterministic")
    func rerankOverlapFreshness() {
        let ranker = ResultReranker()
        let old = result(title: "Swift concurrency guide", host: "old.example", daysOld: 400, score: 0.5)
        let fresh = result(title: "Swift concurrency guide", host: "new.example", daysOld: 1, score: 0.5)
        let off = result(title: "Unrelated cooking post", host: "cook.example", daysOld: 0, score: 0.9)
        let ranked = ranker.rank([old, off, fresh], for: "swift concurrency")
        #expect(ranked.first?.url.host == "new.example")
        #expect(ranked.count == 3)
        #expect(ranker.rank([old, off, fresh], for: "swift concurrency").map(\.url.absoluteString)
            == ranker.rank([fresh, old, off], for: "swift concurrency").map(\.url.absoluteString))
    }

    @Test("Max age and host scopes filter")
    func filters() {
        let ranker = ResultReranker()
        let fresh = result(title: "swift news", host: "ok.example", daysOld: 1, score: 0.8)
        let stale = result(title: "swift news", host: "ok.example", daysOld: 90, score: 0.9)
        let blocked = result(title: "swift news", host: "spam.example", daysOld: 1, score: 0.9)
        let aged = ranker.rank([fresh, stale], for: "swift", options: SearchRankingOptions(maxAge: 30 * 86_400))
        #expect(aged.count == 1 && aged.first?.publishedAt == fresh.publishedAt)
        let scoped = ranker.rank([fresh, blocked], for: "swift", options: SearchRankingOptions(blockHosts: ["spam.example"]))
        #expect(scoped.count == 1 && scoped.first?.url.host == "ok.example")
        let allowed = ranker.rank([fresh, blocked], for: "swift", options: SearchRankingOptions(allowHosts: ["ok.example"]))
        #expect(allowed.count == 1)
    }

    @Test("Rewriter returns bounded deterministic variants")
    func rewriter() {
        let w = SearchQueryRewriter()
        #expect(w.variants(for: "  ") == [])
        let v = w.variants(for: "swift concurrency actors guide", maxVariants: 2)
        #expect(v.count == 2 && v[0] == "swift concurrency actors guide")
        #expect(w.variants(for: "swift concurrency actors guide") == w.variants(for: "swift concurrency actors guide"))
    }

    @Test("Semantic boost reorders by meaning, nil keeps keyword order")
    func semanticRerank() {
        struct Stub: SemanticSimilarity {
            func similarity(between query: String, and text: String) -> Double? {
                text.contains("meaning-match") ? 1.0 : 0.0
            }
        }
        let ranker = ResultReranker()
        let keyword = SearchResult(title: "swift concurrency", url: URL(string: "https://k.example/a")!, snippet: "swift concurrency")
        let semantic = SearchResult(title: "unrelated words", url: URL(string: "https://s.example/a")!, snippet: "meaning-match content here")
        let plain = ranker.rank([keyword, semantic], for: "swift concurrency")
        #expect(plain.first?.url.host == "k.example")
        let boosted = ranker.rank([keyword, semantic], for: "swift concurrency", similarity: Stub(), semanticWeight: 2.0)
        #expect(boosted.first?.url.host == "s.example")
        struct NilStub: SemanticSimilarity {
            func similarity(between query: String, and text: String) -> Double? { nil }
        }
        #expect(ranker.rank([keyword, semantic], for: "swift concurrency", similarity: NilStub()).map(\.url.absoluteString)
            == plain.map(\.url.absoluteString))
    }

    @Test("Apple sentence similarity stays in cosine bounds when available")
    func appleSimilarityBounds() {
        let apple = NaturalLanguageSimilarity()
        guard apple.isAvailable else { return }
        let value = apple.similarity(between: "swift concurrency tasks", and: "structured concurrency with tasks")
        if let value {
            #expect(value >= -0.01 && value <= 1.01)
        }
        #expect(apple.similarity(between: "", and: "") == nil)
    }

    @Test("Registry merges engines and dedupes URLs")
    func registry() async {
        struct Stub: SearchEngine {
            let hits: [SearchResult]
            func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult] { hits }
            func checkHealth() async -> Bool { true }
        }
        let shared = URL(string: "https://dup.example/page?x=1")!
        let registry = SearchEngineRegistry()
        await registry.register(name: "a", engine: Stub(hits: [SearchResult(title: "A", url: shared, snippet: "a")]))
        await registry.register(name: "b", engine: Stub(hits: [
            SearchResult(title: "B", url: shared, snippet: "b"),
            SearchResult(title: "C", url: URL(string: "https://other.example/c")!, snippet: "c"),
        ]))
        let out = await registry.searchAll("q", limit: 10)
        #expect(out.count == 2)
        #expect((await registry.names).sorted() == ["a", "b"])
    }
}
