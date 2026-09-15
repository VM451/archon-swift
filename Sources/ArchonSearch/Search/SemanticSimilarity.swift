import Foundation
import NaturalLanguage

/// Vendor-neutral semantic similarity seam (SEARCH-002: neural-search answer).
///
/// Implementations score query-to-result meaning overlap. The bundled Apple
/// implementation reuses on-device `NLEmbedding` sentence vectors: no model
/// download, no network, no new dependency. Fails soft to `nil` per pair.
public protocol SemanticSimilarity: Sendable {
    func similarity(between query: String, and text: String) -> Double?
}

/// Apple on-device sentence-embedding similarity.
///
/// Immutable after init; the underlying `NLEmbedding` is only ever used for
/// read-only vector lookups, so the small unchecked boundary is safe.
public final class NaturalLanguageSimilarity: SemanticSimilarity, @unchecked Sendable {
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    public var isAvailable: Bool { embedding != nil }

    public func similarity(between query: String, and text: String) -> Double? {
        guard let embedding,
              !query.isEmpty, !text.isEmpty,
              let queryVector = try? embedding.vector(for: query),
              let textVector = try? embedding.vector(for: String(text.prefix(500))),
              queryVector.count == textVector.count, !queryVector.isEmpty
        else { return nil }
        var dot = 0.0, queryNorm = 0.0, textNorm = 0.0
        for index in queryVector.indices {
            dot += queryVector[index] * textVector[index]
            queryNorm += queryVector[index] * queryVector[index]
            textNorm += textVector[index] * textVector[index]
        }
        guard queryNorm > 0, textNorm > 0 else { return nil }
        return dot / (sqrt(queryNorm) * sqrt(textNorm))
    }
}
