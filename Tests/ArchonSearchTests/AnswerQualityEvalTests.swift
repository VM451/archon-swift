import Testing
import Foundation
@testable import ArchonSearch

@Suite("Answer Quality Eval Tests")
struct AnswerQualityEvalTests {
    private func result(title: String, host: String, snippet: String) -> SearchResult {
        SearchResult(
            title: title,
            url: URL(string: "https://\(host)/page")!,
            snippet: snippet,
            score: 0.9
        )
    }

    private func loadJSONFixtures() throws -> [AnswerQualityFixture] {
        let here = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        let url = here.appendingPathComponent("Fixtures/answer-quality.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AnswerQualityFixture].self, from: data)
    }

    @Test("Fixture file stays within the 200-fixture bound")
    func fixtureBound() throws {
        let fixtures = try loadJSONFixtures()
        #expect(fixtures.count == 8)
        #expect(fixtures.count <= 200)
    }

    @Test("Citation precision and recall on fixtures")
    func precisionRecall() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval().score(fixtures: fixtures)
        #expect(scored.perFixture.count == fixtures.count)

        let full = try #require(scored.perFixture.first)
        #expect(full.citationPrecision == 1.0)
        #expect(full.citationRecall == 1.0)
        #expect(full.hallucinationCount == 0)

        let partial = scored.perFixture[1]
        #expect(partial.citationPrecision == 1.0)
        #expect(partial.citationRecall == 0.5)

        let hallucinatedSource = scored.perFixture[2]
        #expect(hallucinatedSource.citationPrecision == 0.5)
        #expect(hallucinatedSource.citationRecall == 1.0)
        #expect(hallucinatedSource.hallucinationCount == 1)
        #expect(hallucinatedSource.groundedness == 0.5)

        let bareNumber = scored.perFixture[6]
        #expect(bareNumber.citationPrecision == 1.0)
        #expect(bareNumber.citationRecall == 1.0)
    }

    @Test("Hallucinations counted fail-closed including bad passages")
    func hallucinationsFailClosed() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval().score(fixtures: fixtures)
        let badPassage = scored.perFixture[3]
        #expect(badPassage.hallucinationCount == 1)
        #expect(badPassage.citationPrecision == 0.0)
        #expect(badPassage.groundedness == 0.0)

        let inline = AnswerQualityFixture(
            query: "q",
            results: [result(title: "T", host: "h.example", snippet: "text")],
            answer: "Claim [S1] plus invented [S2] plus bad passage [S1/P9].",
            expectedCited: ["S1"]
        )
        let one = try AnswerQualityEval().score(fixtures: [inline]).perFixture[0]
        #expect(one.hallucinationCount == 2)
        #expect(one.citationPrecision == 0.5)
        #expect(abs(one.groundedness - (1.0 / 3.0)) < 1e-9)
    }

    @Test("Abstention fixture passes")
    func abstention() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval().score(fixtures: fixtures)
        let abstain = scored.perFixture[4]
        #expect(abstain.abstainedCorrectly == true)
        #expect(abstain.citationPrecision == 1.0)
        #expect(abstain.citationRecall == 1.0)

        let wrongAbstain = AnswerQualityFixture(
            query: "q",
            results: [result(title: "T", host: "h.example", snippet: "text")],
            answer: "Actors exist [S1].",
            expectedCited: ["S1"],
            mustAbstain: true
        )
        let failed = try AnswerQualityEval().score(fixtures: [wrongAbstain]).perFixture[0]
        #expect(failed.abstainedCorrectly == false)
    }

    @Test("Injection fixture is neutralized with envelope intact")
    func injectionNeutralized() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval().score(fixtures: fixtures)
        let injected = scored.perFixture[5]
        #expect(injected.injectionNeutralized == true)

        let builder = ContextBuilder()
        let sanitized = builder.sanitizeText(fixtures[5].answer)
        #expect(sanitized.contains("[FILTERED_INJECTION]"))
        #expect(AnswerQualityEval.containsInjection(sanitized) == false)
        #expect(AnswerQualityEval.containsInjection(fixtures[5].answer) == true)
    }

    @Test("Budget truncation is deterministic")
    func truncationDeterministic() throws {
        let heavy = AnswerQualityFixture(
            query: "q",
            results: [
                result(title: "A", host: "a.example", snippet: String(repeating: "alpha ", count: 500)),
                result(title: "B", host: "b.example", snippet: String(repeating: "beta ", count: 500)),
            ],
            answer: "Summary [S1].",
            expectedCited: ["S1"]
        )
        let small = AnswerQualityEval(builder: ContextBuilder(maxCharacters: 400))
        let first = try small.score(fixtures: [heavy])
        let second = try small.score(fixtures: [heavy])
        #expect(first.perFixture[0].deterministic == true)
        #expect(first.perFixture == second.perFixture)
        #expect(first.aggregate == second.aggregate)
    }

    @Test("Aggregate is the mean of per-fixture scores")
    func aggregateIsMean() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval().score(fixtures: fixtures)
        let per = scored.perFixture
        let count = Double(per.count)
        func mean(_ keyPath: KeyPath<AnswerQualityScore, Double>) -> Double {
            per.reduce(0) { $0 + $1[keyPath: keyPath] } / count
        }
        #expect(abs(scored.aggregate.citationPrecision - mean(\.citationPrecision)) < 1e-9)
        #expect(abs(scored.aggregate.citationRecall - mean(\.citationRecall)) < 1e-9)
        #expect(abs(scored.aggregate.hallucinationCount - mean(\.hallucinationCount)) < 1e-9)
        #expect(abs(scored.aggregate.groundedness - mean(\.groundedness)) < 1e-9)
        #expect(scored.aggregate.abstainedCorrectly == per.reduce(true) { $0 && $1.abstainedCorrectly })
        #expect(scored.aggregate.injectionNeutralized == per.reduce(true) { $0 && $1.injectionNeutralized })
        #expect(scored.aggregate.deterministic == true)
        for score in per {
            #expect(score.deterministic)
        }
    }

    @Test("Empty fixtures throw a typed error")
    func emptyThrows() {
        #expect(throws: SearchError.noResultsFound) {
            try AnswerQualityEval().score(fixtures: [])
        }
    }

    @Test("maxFixtures truncates deterministically")
    func maxFixturesBound() throws {
        let fixtures = try loadJSONFixtures()
        let scored = try AnswerQualityEval(maxFixtures: 2).score(fixtures: fixtures)
        #expect(scored.perFixture.count == 2)
        let full = try AnswerQualityEval().score(fixtures: fixtures)
        #expect(scored.perFixture == Array(full.perFixture.prefix(2)))
    }

    @Test("Citation key normalization accepts aliases")
    func keyNormalization() {
        #expect(AnswerQualityEval.normalizeCitationKey("S1") == "S1")
        #expect(AnswerQualityEval.normalizeCitationKey("[s2/p1]") == "S2")
        #expect(AnswerQualityEval.normalizeCitationKey("3") == "S3")
    }
}
