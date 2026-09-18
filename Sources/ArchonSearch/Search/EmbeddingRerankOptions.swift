import Foundation

/// Opt-in on-device embedding rerank controls (SEARCH-002/SEARCH-004).
///
/// Pure value type: when `enabled`, `ResultReranker` blends an
/// Apple-API (`NLEmbedding`, no downloads) meaning-overlap boost into the
/// keyword score. `nil` options or `enabled == false` keeps keyword behavior
/// exactly. Bounds are enforced at use time via the `clamped*` accessors so
/// Codable round-trips preserve the authored values.
public struct EmbeddingRerankOptions: Sendable, Codable, Equatable {
    /// Master switch. Default `false`: rerank is strictly opt-in.
    public var enabled: Bool
    /// Blend weight for the semantic boost. Clamped to 0...1 at use time.
    public var weight: Double
    /// BCP-47 language for the sentence embedding. Default `"en"`.
    /// Unavailable language -> keyword-only fallback, never throws.
    public var language: String
    /// Per-result character bound for embedding input. Bound 1...2000.
    public var maxCharsPerResult: Int

    public init(
        enabled: Bool = false,
        weight: Double = 0.4,
        language: String = "en",
        maxCharsPerResult: Int = 500
    ) {
        self.enabled = enabled
        self.weight = weight
        self.language = language
        self.maxCharsPerResult = maxCharsPerResult
    }

    /// `weight` clamped to 0...1. NaN fails closed to 0.
    public var clampedWeight: Double {
        guard weight.isFinite else { return 0 }
        return min(max(weight, 0), 1)
    }

    /// `maxCharsPerResult` clamped to 1...2000.
    public var clampedMaxChars: Int {
        min(max(maxCharsPerResult, 1), 2000)
    }
}
