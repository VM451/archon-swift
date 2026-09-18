import Foundation

/// Owned sparse-plus-dense hybrid ranking owned by `ArchonMemory`.
///
/// This value type is the single home of the hybrid blend formula previously
/// embedded in `LocalVectorStore.search`. Index adapters and stores delegate
/// to it so ranking stays identical everywhere: dense cosine similarity scaled
/// by `alpha`, plus sparse text rank scaled by `beta` and exponential
/// recency decay, all multiplied by the per-record importance weight.
///
/// The formula is, exactly:
///
///     score = (alpha * dense + beta * sparse * exp(-decayLambda * ageDays)) * weight
///
/// where a missing dense component (`nil`, e.g. records without embeddings)
/// contributes zero. Inputs are clamped fail-closed: negative sparse scores,
/// ages, and weights behave as zero, and the final score never goes negative
/// (a negative dense similarity can otherwise drag the blend below zero;
/// retrieval treats that as "do not return", identical to the previous
/// `finalScore > 0` gate).
public struct HybridRankingOptions: Sendable, Equatable, Codable {
    public var alpha: Float
    public var beta: Float
    public var decayLambda: Float

    public init(alpha: Float = 0.7, beta: Float = 0.3, decayLambda: Float = 0.01) {
        self.alpha = max(0, alpha)
        self.beta = max(0, beta)
        self.decayLambda = max(0, decayLambda)
    }

    public static let standard = HybridRankingOptions()

    /// Scores one candidate with the owned hybrid blend formula.
    ///
    /// - Parameters:
    ///   - dense: Dense cosine similarity in [-1, 1], or `nil` when the
    ///     record has no embedding (contributes zero).
    ///   - sparse: Sparse text rank, higher-is-better. Negative values clamp
    ///     to zero.
    ///   - ageDays: Whole or fractional days since last access. Negative
    ///     values clamp to zero (no future boost).
    ///   - weight: Per-record importance multiplier. Negative values clamp
    ///     to zero.
    /// - Returns: The blended score, clamped to be non-negative and finite.
    public func score(dense: Float?, sparse: Float, ageDays: Float, weight: Float) -> Float {
        let denseComponent = dense ?? 0
        let sparseComponent = max(0, sparse)
        let age = max(0, ageDays)
        let importance = max(0, weight)
        let decay = exp(-decayLambda * age)
        let blended = (alpha * denseComponent + beta * sparseComponent * decay) * importance
        guard blended.isFinite else { return 0 }
        return max(0, blended)
    }

    /// Recency decay factor for an age in days.
    public func decay(ageDays: Float) -> Float {
        let decayed = exp(-decayLambda * max(0, ageDays))
        return decayed.isFinite ? decayed : 0
    }
}

/// One rankable retrieval candidate for `HybridRankingOptions.rank(_:)`.
public struct HybridRankingCandidate: Sendable, Equatable {
    public let id: UUID
    public let dense: Float?
    public let sparse: Float
    public let ageDays: Float
    public let weight: Float

    public init(id: UUID, dense: Float?, sparse: Float, ageDays: Float, weight: Float) {
        self.id = id
        self.dense = dense
        self.sparse = sparse
        self.ageDays = ageDays
        self.weight = weight
    }
}

/// A scored candidate with its blended score attached.
public struct HybridRankedCandidate: Sendable, Equatable {
    public let id: UUID
    public let score: Float
    public let dense: Float?
    public let sparse: Float

    public init(id: UUID, score: Float, dense: Float?, sparse: Float) {
        self.id = id
        self.score = score
        self.dense = dense
        self.sparse = sparse
    }
}

extension HybridRankingOptions {
    /// Scores and orders candidates best-first with a deterministic tie-break.
    ///
    /// Ordering is by descending blended score; exact ties break by ascending
    /// UUID string so repeated runs over the same candidates return the same
    /// order. Candidates scoring zero or less are dropped, matching the
    /// retrieval gate that never returns non-positive blends.
    public func rank(_ candidates: [HybridRankingCandidate]) -> [HybridRankedCandidate] {
        var ranked: [HybridRankedCandidate] = []
        ranked.reserveCapacity(candidates.count)
        for candidate in candidates {
            let blended = score(
                dense: candidate.dense,
                sparse: candidate.sparse,
                ageDays: candidate.ageDays,
                weight: candidate.weight
            )
            guard blended > 0 else { continue }
            ranked.append(HybridRankedCandidate(
                id: candidate.id,
                score: blended,
                dense: candidate.dense,
                sparse: candidate.sparse
            ))
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.uuidString < $1.id.uuidString
        }
        return ranked
    }
}
