import Foundation

/// Configuration options controlling an autonomous multi-round research session.
public struct ResearchOptions: Sendable, Codable, Equatable {
    public var maxRounds: Int
    public var queriesPerRound: Int
    public var maxDocuments: Int
    public var timeout: TimeInterval
    public var tokenBudget: Int
    public var minPassageScore: Double

    public init(
        maxRounds: Int = 3,
        queriesPerRound: Int = 4,
        maxDocuments: Int = 15,
        timeout: TimeInterval = 60.0,
        tokenBudget: Int = 4000,
        minPassageScore: Double = 0.2
    ) {
        self.maxRounds = max(1, min(maxRounds, 10))
        self.queriesPerRound = max(1, min(queriesPerRound, 10))
        self.maxDocuments = max(1, min(maxDocuments, 50))
        self.timeout = max(5.0, timeout)
        self.tokenBudget = max(500, tokenBudget)
        self.minPassageScore = minPassageScore
    }

    /// Fast options preset for low-latency interactive workflows.
    public static let fast = ResearchOptions(
        maxRounds: 1,
        queriesPerRound: 2,
        maxDocuments: 5,
        timeout: 15.0
    )

    /// Deep options preset for comprehensive evidence gathering.
    public static let deep = ResearchOptions(
        maxRounds: 4,
        queriesPerRound: 5,
        maxDocuments: 25,
        timeout: 120.0
    )
}
