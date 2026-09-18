import Foundation

/// Action taken when a contributor exceeds its latency budget. Only
/// fail-closed is supported; skip-mode is explicitly deferred so partial
/// context is never silently returned.
public enum TimeoutAction: Sendable, Equatable {
    case failClosed
}

/// Per-contributor latency budget. Non-positive timeouts are rejected at init.
public struct ContributorLatencyPolicy: Sendable, Equatable {
    public let perContributorTimeout: Duration
    public let onTimeout: TimeoutAction

    public init(perContributorTimeout: Duration, onTimeout: TimeoutAction = .failClosed) throws {
        guard perContributorTimeout > .zero else {
            throw ContributorLatencyError.invalidPolicy
        }
        self.perContributorTimeout = perContributorTimeout
        self.onTimeout = onTimeout
    }
}

/// Typed contributor-latency failures.
public enum ContributorLatencyError: Error, LocalizedError, Equatable, Sendable {
    case invalidPolicy
    case contributorTimeout(id: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "Contributor latency policies require a positive per-contributor timeout."
        case .contributorTimeout(let id):
            "Context contributor timed out: \(id)"
        }
    }
}
