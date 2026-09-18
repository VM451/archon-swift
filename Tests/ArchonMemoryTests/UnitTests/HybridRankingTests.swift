import Testing
import Foundation
@testable import ArchonMemory

@Suite("Hybrid Ranking Options")
struct HybridRankingTests {
    private func expectedBlend(
        alpha: Float,
        beta: Float,
        lambda: Float,
        dense: Float?,
        sparse: Float,
        ageDays: Float,
        weight: Float
    ) -> Float {
        let v = Double(dense ?? 0)
        let s = max(0, Double(sparse))
        let age = max(0, Double(ageDays))
        let w = max(0, Double(weight))
        let blended = (Double(alpha) * v + Double(beta) * s * exp(-Double(lambda) * age)) * w
        guard blended.isFinite else { return 0 }
        return max(0, Float(blended))
    }

    @Test("Blend matches the historical LocalVectorStore formula")
    func blendEquivalence() {
        let options = HybridRankingOptions(alpha: 0.7, beta: 0.3, decayLambda: 0.01)
        let denseValues: [Float?] = [nil, -0.2, 0, 0.5, 1.0]
        for dense in denseValues {
            for sparse in [Float(0), 0.25, 1.0] {
                for age in [Float(0), 1, 30] {
                    for weight in [Float(0), 0.5, 1.0, 2.0] {
                        let actual = options.score(
                            dense: dense,
                            sparse: sparse,
                            ageDays: age,
                            weight: weight
                        )
                        let expected = expectedBlend(
                            alpha: 0.7,
                            beta: 0.3,
                            lambda: 0.01,
                            dense: dense,
                            sparse: sparse,
                            ageDays: age,
                            weight: weight
                        )
                        #expect(abs(actual - expected) < 1e-5)
                    }
                }
            }
        }
    }

    @Test("Missing dense component behaves as pure sparse retrieval")
    func nilDenseSparsityPath() {
        let options = HybridRankingOptions.standard
        let sparseOnly = options.score(dense: nil, sparse: 0.8, ageDays: 2, weight: 1)
        let explicitZero = options.score(dense: 0, sparse: 0.8, ageDays: 2, weight: 1)
        #expect(sparseOnly == explicitZero)
        #expect(sparseOnly > 0)
        #expect(options.score(dense: nil, sparse: 0, ageDays: 0, weight: 1) == 0)
    }

    @Test("Rank is deterministic with UUID tie-break and drops zero scores")
    func rankDeterminismAndTieBreak() {
        let options = HybridRankingOptions.standard
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let upper = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let candidates = [
            HybridRankingCandidate(id: upper, dense: 0.5, sparse: 0.5, ageDays: 0, weight: 1),
            HybridRankingCandidate(id: zero, dense: nil, sparse: 0, ageDays: 0, weight: 1),
            HybridRankingCandidate(id: lower, dense: 0.5, sparse: 0.5, ageDays: 0, weight: 1),
        ]
        let first = options.rank(candidates)
        #expect(first.map(\.id) == [lower, upper])
        for _ in 0..<5 {
            #expect(options.rank(candidates).map(\.id) == [lower, upper])
        }
        #expect(first[0].score == first[1].score)
        #expect(first[0].score > 0)
    }

    @Test("Negative inputs clamp to zero instead of boosting")
    func zeroAndNegativeClamp() {
        let clamped = HybridRankingOptions(alpha: -1, beta: -2, decayLambda: -3)
        #expect(clamped.alpha == 0)
        #expect(clamped.beta == 0)
        #expect(clamped.decayLambda == 0)

        let options = HybridRankingOptions.standard
        #expect(options.score(dense: 1, sparse: -5, ageDays: 0, weight: 1)
            == options.score(dense: 1, sparse: 0, ageDays: 0, weight: 1))
        #expect(options.score(dense: 0.5, sparse: 0.5, ageDays: -10, weight: 1)
            == options.score(dense: 0.5, sparse: 0.5, ageDays: 0, weight: 1))
        #expect(options.score(dense: 1, sparse: 1, ageDays: 0, weight: -2) == 0)
        #expect(options.score(dense: -1, sparse: 0, ageDays: 0, weight: 1) == 0)
        #expect(options.decay(ageDays: -10) == 1)
        #expect(options.decay(ageDays: 0) == 1)
        #expect(options.rank([
            HybridRankingCandidate(id: UUID(), dense: -1, sparse: 0, ageDays: 0, weight: 1),
        ]).isEmpty)
    }

    @Test("Recency decay decreases with age")
    func decayDecreasesWithAge() {
        let options = HybridRankingOptions.standard
        let fresh = options.score(dense: 0, sparse: 1, ageDays: 0, weight: 1)
        let old = options.score(dense: 0, sparse: 1, ageDays: 100, weight: 1)
        #expect(fresh > old)
        #expect(old > 0)
    }
}
