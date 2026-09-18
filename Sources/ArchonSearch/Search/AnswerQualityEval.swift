import Foundation

/// A deterministic answer-quality fixture (SEARCH-002 neural-search gap).
///
/// Pure data: a query, the retrieved results the answer may cite, the answer
/// text under test, the expected cited source keys (`"S1"`, `"S2"`, ...), and
/// whether the correct behavior is abstention. Decodable from the bundled
/// `answer-quality.json` fixture set (<= 200 fixtures).
public struct AnswerQualityFixture: Sendable, Codable, Equatable {
    public var query: String
    public var results: [SearchResult]
    public var answer: String
    public var expectedCited: [String]
    public var mustAbstain: Bool

    public init(
        query: String,
        results: [SearchResult],
        answer: String,
        expectedCited: [String] = [],
        mustAbstain: Bool = false
    ) {
        self.query = query
        self.results = results
        self.answer = answer
        self.expectedCited = expectedCited
        self.mustAbstain = mustAbstain
    }
}

/// Scores for one fixture (or the aggregate mean across fixtures).
public struct AnswerQualityScore: Sendable, Equatable {
    /// True-positive citations / all parsed citations. 1.0 when none parsed.
    public var citationPrecision: Double
    /// True-positive citations / expected citations. 1.0 when none expected.
    public var citationRecall: Double
    /// Count of fail-closed hallucinations (unknown source or passage).
    public var hallucinationCount: Double
    /// Valid citations / all parsed citations. 1.0 when none parsed.
    public var groundedness: Double
    /// Abstention behavior matches `mustAbstain`.
    public var abstainedCorrectly: Bool
    /// No live injection directive survives sanitizing and the reference
    /// envelope is intact; fixtures containing injections must show the
    /// `[FILTERED_INJECTION]` marker.
    public var injectionNeutralized: Bool
    /// Re-running rank + context build + scoring reproduces this score.
    public var deterministic: Bool

    public init(
        citationPrecision: Double,
        citationRecall: Double,
        hallucinationCount: Double,
        groundedness: Double,
        abstainedCorrectly: Bool,
        injectionNeutralized: Bool,
        deterministic: Bool
    ) {
        self.citationPrecision = citationPrecision
        self.citationRecall = citationRecall
        self.hallucinationCount = hallucinationCount
        self.groundedness = groundedness
        self.abstainedCorrectly = abstainedCorrectly
        self.injectionNeutralized = injectionNeutralized
        self.deterministic = deterministic
    }
}

/// Deterministic, fixture-driven answer-quality evaluation.
///
/// Pure and in-process: ranks fixture results for order-stability, builds the
/// budgeted grounding context, parses/verifies citations fail-closed, and
/// checks abstention plus injection neutralization. No network, no model.
public struct AnswerQualityEval: Sendable {
    public let ranker: ResultReranker
    public let builder: ContextBuilder
    /// Upper bound on scored fixtures per call. Clamped to 1...200.
    public let maxFixtures: Int

    public init(
        ranker: ResultReranker = ResultReranker(),
        builder: ContextBuilder = ContextBuilder(),
        maxFixtures: Int = 200
    ) {
        self.ranker = ranker
        self.builder = builder
        self.maxFixtures = min(max(maxFixtures, 1), 200)
    }

    /// Scores fixtures, truncated deterministically to the first `maxFixtures`.
    /// Throws `SearchError.noResultsFound` for an empty fixture list.
    public func score(fixtures: [AnswerQualityFixture]) throws -> (perFixture: [AnswerQualityScore], aggregate: AnswerQualityScore) {
        guard !fixtures.isEmpty else { throw SearchError.noResultsFound }
        let scoped = Array(fixtures.prefix(maxFixtures))
        let perFixture = scoped.map { scoreOne($0) }
        return (perFixture, aggregate(of: perFixture))
    }

    // MARK: - Per-fixture scoring

    private func scoreOne(_ fixture: AnswerQualityFixture) -> AnswerQualityScore {
        let firstPass = scorePass(fixture)
        let secondPass = scorePass(fixture)
        let rankedURLs = ranker.rank(fixture.results, for: fixture.query).map(\.url.absoluteString)
        let rankedAgainURLs = ranker.rank(fixture.results, for: fixture.query).map(\.url.absoluteString)
        var score = firstPass
        score.deterministic = (firstPass == secondPass) && (rankedURLs == rankedAgainURLs)
        return score
    }

    private func scorePass(_ fixture: AnswerQualityFixture) -> AnswerQualityScore {
        let sources = makeSources(from: fixture.results)
        let context = builder.buildContext(from: sources)
        let graph = CitationGraph(sources: sources)
        let parsed = graph.parseCitations(from: fixture.answer)
        let (valid, hallucinations) = graph.verify(citations: parsed)

        let expected = Set(fixture.expectedCited.map(Self.normalizeCitationKey))
        let citedSources = Set(parsed.map { "S\($0.sourceIndex)" })
        let validSources = Set(valid.map { "S\($0.sourceIndex)" })
        let truePositives = validSources.intersection(expected).count

        let precision: Double
        if citedSources.isEmpty {
            precision = 1.0
        } else {
            precision = Double(truePositives) / Double(citedSources.count)
        }
        let recall: Double
        if expected.isEmpty {
            recall = 1.0
        } else {
            recall = Double(truePositives) / Double(expected.count)
        }
        let groundedness = parsed.isEmpty ? 1.0 : Double(valid.count) / Double(parsed.count)

        let abstained = Self.containsAbstention(fixture.answer)
        let abstainedCorrectly = fixture.mustAbstain
            ? (abstained && parsed.isEmpty)
            : !abstained

        let sanitized = builder.sanitizeText(fixture.answer)
        let envelopeIntact = context.contains("<reference_data>") && context.contains("</reference_data>")
        let originalHasInjection = Self.containsInjection(fixture.answer)
        let sanitizedHasInjection = Self.containsInjection(sanitized)
        let injectionNeutralized = envelopeIntact && !sanitizedHasInjection
            && (!originalHasInjection || sanitized.contains("[FILTERED_INJECTION]"))

        return AnswerQualityScore(
            citationPrecision: precision,
            citationRecall: recall,
            hallucinationCount: Double(hallucinations.count),
            groundedness: groundedness,
            abstainedCorrectly: abstainedCorrectly,
            injectionNeutralized: injectionNeutralized,
            deterministic: false
        )
    }

    private func aggregate(of scores: [AnswerQualityScore]) -> AnswerQualityScore {
        guard !scores.isEmpty else {
            return AnswerQualityScore(
                citationPrecision: 0, citationRecall: 0, hallucinationCount: 0,
                groundedness: 0, abstainedCorrectly: false,
                injectionNeutralized: false, deterministic: false
            )
        }
        let count = Double(scores.count)
        func mean(_ keyPath: KeyPath<AnswerQualityScore, Double>) -> Double {
            scores.reduce(0) { $0 + $1[keyPath: keyPath] } / count
        }
        return AnswerQualityScore(
            citationPrecision: mean(\.citationPrecision),
            citationRecall: mean(\.citationRecall),
            hallucinationCount: mean(\.hallucinationCount),
            groundedness: mean(\.groundedness),
            abstainedCorrectly: scores.allSatisfy(\.abstainedCorrectly),
            injectionNeutralized: scores.allSatisfy(\.injectionNeutralized),
            deterministic: scores.allSatisfy(\.deterministic)
        )
    }

    private func makeSources(from results: [SearchResult]) -> [Source] {
        results.map { result in
            let sourceID = UUID()
            let passage = SourcePassage(
                sourceID: sourceID,
                text: result.title + "\n" + result.snippet,
                score: result.score ?? 0.5
            )
            return Source(
                id: sourceID,
                url: result.url,
                title: result.title,
                passages: [passage]
            )
        }
    }

    // MARK: - Normalization helpers

    /// Normalizes an expected-citation entry to a source key (`"S1"`).
    /// Accepts `"S1"`, `"[S1]"`, `"s1/p2"`, or bare `"1"`; anything else is
    /// kept verbatim so it fail-closed never matches.
    static func normalizeCitationKey(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let slash = token.firstIndex(of: "/") {
            token = String(token[..<slash])
        }
        if token.allSatisfy(\.isNumber), !token.isEmpty {
            return "S" + token
        }
        return token
    }

    private static let abstentionPhrases = [
        "don't know", "do not know", "no information", "cannot answer",
        "can't answer", "can not answer", "insufficient information",
        "insufficient evidence", "unable to answer", "no results found",
        "could not find",
    ]

    static func containsAbstention(_ text: String) -> Bool {
        let lower = text.lowercased()
        return abstentionPhrases.contains { lower.contains($0) }
    }

    private static let injectionMarkers = [
        "ignore previous instructions",
        "ignore all previous instructions",
        "ignore prior instructions",
        "<|im_start|>",
        "<|im_end|>",
        "<system>",
    ]

    static func containsInjection(_ text: String) -> Bool {
        let lower = text.lowercased()
        return injectionMarkers.contains { lower.contains($0) }
    }
}
