import Foundation
import Testing
import ArchonContext

private struct ProfileContributor: ContextContributor {
    let id: String
    let fragment: ContextFragment

    func makeContextFragment() async throws -> ContextFragment { fragment }
}

struct TokenProfileTests {
    @Test("Fallback profile matches the UTF-8 estimator exactly")
    func fallbackParity() {
        let fallback = FamilyAwareTokenEstimator(family: .utf8Fallback)
        let legacy = UTF8ContextTokenEstimator()
        for text in ["", "a", "abcd", "abcdefgh", String(repeating: "xy", count: 500), "héllo-世界"] {
            #expect(fallback.estimateTokens(text) == legacy.estimateTokens(text))
        }
        #expect(FamilyAwareTokenEstimator.divisor(for: .utf8Fallback) == 4)
    }

    @Test("Per-family divisors differ deterministically")
    func perFamilyDivisors() {
        let text = String(repeating: "a", count: 12)
        let gemma = FamilyAwareTokenEstimator(family: .gemma).estimateTokens(text)
        let gpt = FamilyAwareTokenEstimator(family: .gpt).estimateTokens(text)
        #expect(FamilyAwareTokenEstimator.divisor(for: .gemma) == 3)
        #expect(FamilyAwareTokenEstimator.divisor(for: .gpt) == 4)
        #expect(gemma == 4)
        #expect(gpt == 3)
        #expect(gemma != gpt)
        #expect(ModelFamilyTokenProfile.allCases.count == 7)
    }

    @Test("Explicit override clamps to a positive divisor")
    func overrideClamp() {
        #expect(FamilyAwareTokenEstimator(family: .gpt, charsPerToken: 0).charsPerToken == 1)
        #expect(FamilyAwareTokenEstimator(family: .gpt, charsPerToken: -5).charsPerToken == 1)
        #expect(FamilyAwareTokenEstimator(family: .gpt, charsPerToken: 2).estimateTokens("abcd") == 2)
        #expect(FamilyAwareTokenEstimator(family: .gpt).estimateTokens("") == 0)
    }

    @Test("Family estimator drives token budgets")
    func budgetInterplay() async throws {
        let content = String(repeating: "a", count: 40)
        let builder = ContextBuilder(
            contributors: [
                ProfileContributor(
                    id: "a",
                    fragment: ContextFragment(id: "a", source: "a", content: content)
                )
            ],
            tokenEstimator: FamilyAwareTokenEstimator(family: .gemma)
        )
        let snapshot = try await builder.snapshot(budget: try ContextBudget(maxTokens: 5))
        let kept = try #require(snapshot.fragments.first)
        #expect(kept.metadata["archon.truncated"] == "true")
        let measured = FamilyAwareTokenEstimator(family: .gemma)
            .estimateTokens("[a]\n" + kept.content)
        #expect(measured <= 5)
    }
}
