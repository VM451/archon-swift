import Foundation

/// Politeness-aware crawl scheduling controls (SEARCH-004).
///
/// Bounds queue growth, host backoff, and retry behavior. All values are
/// clamped at use time; the actor never sleeps for politeness when these are
/// configured — unready hosts are skipped and the next ready host (or `nil`)
/// is returned instead.
public struct CrawlScheduleOptions: Sendable, Codable, Equatable {
    /// Maximum pending nodes kept per host; lowest-priority extras are
    /// dropped deterministically at enqueue time. Clamped to >= 1.
    public var maxQueuedPerHost: Int
    /// Maximum distinct hosts with in-flight (`crawling`) nodes. New hosts
    /// are withheld while at capacity. Clamped to >= 1.
    public var maxHostsInFlight: Int
    /// Node failures before a node is marked `.failed`. Clamped to >= 1.
    public var maxRetries: Int
    /// Base politeness delay between same-host dequeues. Clamped to >= 0.
    public var baseDelay: TimeInterval
    /// Maximum politeness delay (robots crawl-delay is clamped to this).
    public var maxDelay: TimeInterval
    /// Hard cap for every backoff, including server `Retry-After`.
    /// Default 300s; clamped to >= 1.
    public var backoffCap: TimeInterval
    /// Priority points subtracted per crawl depth. Clamped to >= 0.
    public var depthPenalty: Double
    /// Priority points subtracted per recorded host failure. Clamped to >= 0.
    public var failurePenalty: Double

    public init(
        maxQueuedPerHost: Int = 100,
        maxHostsInFlight: Int = 4,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        backoffCap: TimeInterval = 300.0,
        depthPenalty: Double = 0.5,
        failurePenalty: Double = 1.0
    ) {
        self.maxQueuedPerHost = maxQueuedPerHost
        self.maxHostsInFlight = maxHostsInFlight
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.backoffCap = backoffCap
        self.depthPenalty = depthPenalty
        self.failurePenalty = failurePenalty
    }

    public var clampedMaxQueuedPerHost: Int { max(1, maxQueuedPerHost) }
    public var clampedMaxHostsInFlight: Int { max(1, maxHostsInFlight) }
    public var clampedMaxRetries: Int { max(1, maxRetries) }
    public var clampedBaseDelay: TimeInterval { clampedDelay(baseDelay) }
    public var clampedMaxDelay: TimeInterval { max(0, maxDelay) }
    public var clampedBackoffCap: TimeInterval { max(1, backoffCap) }
    public var clampedDepthPenalty: Double { max(0, depthPenalty) }
    public var clampedFailurePenalty: Double { max(0, failurePenalty) }

    /// Clamps an arbitrary delay to 0...backoffCap. Non-finite fails to cap.
    public func clampedDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return clampedBackoffCap }
        return min(max(delay, 0), clampedBackoffCap)
    }

    /// Exponential backoff for a 1-based failure count, capped by
    /// `maxDelay` and `backoffCap`. The exponent is bounded so large counts
    /// cannot overflow.
    public func exponentialDelay(failures: Int) -> TimeInterval {
        let capped = min(max(failures, 1), 20)
        let delay = clampedBaseDelay * pow(2.0, Double(capped - 1))
        return min(clampedDelay(delay), clampedMaxDelay)
    }
}

/// Outcome of a host fetch, reported back to the scheduler.
public enum CrawlHostOutcome: Sendable, Equatable {
    /// Fetch succeeded: host backoff clears, failure counts reset.
    case success
    /// HTTP 429 (or equivalent): backs the host off by `retryAfter`
    /// (defaulting to the exponential delay), clamped to `backoffCap`.
    case rateLimited(retryAfter: TimeInterval?)
    /// HTTP 5xx (or equivalent): exponential backoff, capped.
    case serverError
}
