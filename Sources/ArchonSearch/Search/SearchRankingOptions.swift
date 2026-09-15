import Foundation

/// Ranking controls for local result ordering (SEARCH-002).
///
/// Pure value type: relevance term overlap, freshness decay, and
/// Goggles-style host scoping. No network, no model, deterministic.
public struct SearchRankingOptions: Sendable, Codable, Equatable {
    public var preferRecent: Bool
    /// Results older than this are dropped when they carry a date.
    public var maxAge: TimeInterval?
    /// Half-life in seconds for the freshness boost decay.
    public var freshnessHalfLife: TimeInterval
    /// When non-empty, only these hosts survive.
    public var allowHosts: [String]
    /// Hosts that never survive, checked as suffix match.
    public var blockHosts: [String]
    public var maxResults: Int

    public init(
        preferRecent: Bool = true,
        maxAge: TimeInterval? = nil,
        freshnessHalfLife: TimeInterval = 60 * 60 * 24 * 30,
        allowHosts: [String] = [],
        blockHosts: [String] = [],
        maxResults: Int = 10
    ) {
        self.preferRecent = preferRecent
        self.maxAge = maxAge
        self.freshnessHalfLife = freshnessHalfLife
        self.allowHosts = allowHosts
        self.blockHosts = blockHosts
        self.maxResults = maxResults
    }
}
