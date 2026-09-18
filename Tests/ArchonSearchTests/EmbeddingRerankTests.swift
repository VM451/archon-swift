import Testing
import Foundation
@testable import ArchonSearch

private struct MeaningStub: SemanticSimilarity, Sendable {
    func similarity(between query: String, and text: String) -> Double? {
        text.contains("meaning-match") ? 1.0 : 0.0
    }
}

private struct NilStub: SemanticSimilarity, Sendable {
    func similarity(between query: String, and text: String) -> Double? { nil }
}

private final class RecordingSimilarity: SemanticSimilarity, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var texts: [String] { lock.withLock { stored } }
    func similarity(between query: String, and text: String) -> Double? {
        lock.withLock { stored.append(text) }
        return 0.5
    }
}

@Suite("Embedding Rerank Tests")
struct EmbeddingRerankTests {
    private func keywordResult() -> SearchResult {
        SearchResult(
            title: "swift concurrency",
            url: URL(string: "https://k.example/a")!,
            snippet: "swift concurrency"
        )
    }

    private func semanticResult() -> SearchResult {
        SearchResult(
            title: "unrelated words",
            url: URL(string: "https://s.example/a")!,
            snippet: "meaning-match content here"
        )
    }

    @Test("Disabled embedding keeps keyword parity")
    func disabledParity() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let plain = ranker.rank(results, for: "swift concurrency")
        let disabled = ranker.rank(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: false),
            similarity: MeaningStub()
        )
        #expect(disabled.map(\.url.absoluteString) == plain.map(\.url.absoluteString))
        #expect(disabled.first?.url.host == "k.example")
        let out = ranker.rankWithEmbedding(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: false),
            similarity: MeaningStub()
        )
        #expect(out.usedSemanticRerank == false)
    }

    @Test("Nil embedding keeps keyword parity")
    func nilParity() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let plain = ranker.rank(results, for: "swift concurrency")
        let out = ranker.rankWithEmbedding(
            results, for: "swift concurrency",
            embedding: nil, similarity: MeaningStub()
        )
        #expect(out.results.map(\.url.absoluteString) == plain.map(\.url.absoluteString))
        #expect(out.usedSemanticRerank == false)
    }

    @Test("All-nil similarity keeps keyword parity and reports unused")
    func nilSimilarityParity() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let plain = ranker.rank(results, for: "swift concurrency")
        let out = ranker.rankWithEmbedding(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: true),
            similarity: NilStub()
        )
        #expect(out.results.map(\.url.absoluteString) == plain.map(\.url.absoluteString))
        #expect(out.usedSemanticRerank == false)
    }

    @Test("Unavailable language falls back to keyword-only")
    func unavailableLanguageFallback() {
        let bogus = NaturalLanguageSimilarity(languageCode: "xx-not-a-language")
        #expect(bogus.isAvailable == false)
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let plain = ranker.rank(results, for: "swift concurrency")
        let out = ranker.rankWithEmbedding(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: true, language: "xx-not-a-language")
        )
        #expect(out.results.map(\.url.absoluteString) == plain.map(\.url.absoluteString))
        #expect(out.usedSemanticRerank == false)
    }

    @Test("Non-English language never throws and returns all results")
    func nonEnglishNoThrow() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let ranked = ranker.rank(
            results, for: "concurrence swift",
            embedding: EmbeddingRerankOptions(enabled: true, language: "fr")
        )
        #expect(ranked.count == 2)
        #expect(Set(ranked.map(\.url.absoluteString)) == Set(results.map(\.url.absoluteString)))
    }

    @Test("Weight clamps above 1 and below 0")
    func weightClamp() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let over = ranker.rank(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: true, weight: 2.0),
            similarity: MeaningStub()
        )
        let one = ranker.rank(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: true, weight: 1.0),
            similarity: MeaningStub()
        )
        #expect(over.map(\.url.absoluteString) == one.map(\.url.absoluteString))
        #expect(over.first?.url.host == "s.example")
        let under = ranker.rank(
            results, for: "swift concurrency",
            embedding: EmbeddingRerankOptions(enabled: true, weight: -1.0),
            similarity: MeaningStub()
        )
        let plain = ranker.rank(results, for: "swift concurrency")
        #expect(under.map(\.url.absoluteString) == plain.map(\.url.absoluteString))
        #expect(EmbeddingRerankOptions(weight: 99).clampedWeight == 1.0)
        #expect(EmbeddingRerankOptions(weight: -99).clampedWeight == 0.0)
    }

    @Test("Character bound is respected")
    func charBound() {
        let recorder = RecordingSimilarity()
        let ranker = ResultReranker()
        let long = SearchResult(
            title: "t",
            url: URL(string: "https://long.example/a")!,
            snippet: String(repeating: "x", count: 3000)
        )
        _ = ranker.rank(
            [long], for: "query",
            embedding: EmbeddingRerankOptions(enabled: true, maxCharsPerResult: 100),
            similarity: recorder
        )
        #expect(recorder.texts.count == 1)
        #expect(recorder.texts.allSatisfy { $0.count <= 100 })
        #expect(EmbeddingRerankOptions(maxCharsPerResult: 9999).clampedMaxChars == 2000)
        #expect(EmbeddingRerankOptions(maxCharsPerResult: 0).clampedMaxChars == 1)
    }

    @Test("Enabled rerank is deterministic across input orders")
    func determinismAcrossOrders() {
        let ranker = ResultReranker()
        let third = SearchResult(
            title: "more words", url: URL(string: "https://m.example/a")!,
            snippet: "meaning-match again"
        )
        let a = [keywordResult(), semanticResult(), third]
        let b = [third, keywordResult(), semanticResult()]
        let options = EmbeddingRerankOptions(enabled: true)
        let ra = ranker.rank(a, for: "swift concurrency", embedding: options, similarity: MeaningStub())
        let rb = ranker.rank(b, for: "swift concurrency", embedding: options, similarity: MeaningStub())
        #expect(ra.map(\.url.absoluteString) == rb.map(\.url.absoluteString))
    }

    @Test("Options-carried embedding applies and reports usage")
    func optionsCarriedEmbedding() {
        let ranker = ResultReranker()
        let results = [keywordResult(), semanticResult()]
        let options = SearchRankingOptions(
            embedding: EmbeddingRerankOptions(enabled: true, weight: 1.0)
        )
        let out = ranker.rankWithEmbedding(
            results, for: "swift concurrency",
            options: options, embedding: nil, similarity: MeaningStub()
        )
        #expect(out.results.first?.url.host == "s.example")
        #expect(out.usedSemanticRerank == true)
    }

    @Test("Language-code init strips region subtags")
    func languageCodeRegions() {
        let regional = NaturalLanguageSimilarity(languageCode: "en-US")
        #expect(regional.isAvailable == NaturalLanguageSimilarity().isAvailable)
    }
}
