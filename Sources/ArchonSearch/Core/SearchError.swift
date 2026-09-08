import Foundation

/// Errors that can occur during search, crawl, extraction, or persistence operations.
public enum SearchError: Error, LocalizedError, Sendable, Codable, Equatable, CustomStringConvertible {
    case offline
    case timeout(reason: String)
    case networkPolicy(reason: String)
    case searxng(reason: String)
    case crawl4ai(reason: String)
    case extraction(reason: String)
    case invalidURL(urlString: String)
    case localOnlyRequiresLocalSource
    case localOnlyRequiresStaticLocalCrawl
    case robotsDisallowed(urlString: String)
    case rateLimited(urlString: String, retryAfter: TimeInterval?)
    case extractionFailed(reason: String)
    case networkFailure(urlString: String, statusCode: Int)
    case initializationFailed(reason: String)
    case timeoutBudgetExceeded
    case noResultsFound

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .offline:
            return "Offline: Device is offline or network is unreachable."
        case .timeout(let reason):
            return "Timeout: Operation timed out. \(reason)"
        case .networkPolicy(let reason):
            return "NetworkPolicy: Request rejected by network policy. \(reason)"
        case .searxng(let reason):
            return "SearXNG: Search backend failure. \(reason)"
        case .crawl4ai(let reason):
            return "Crawl4AI: Crawler backend failure. \(reason)"
        case .extraction(let reason):
            return "Extraction: Structured extraction failed. \(reason)"
        case .invalidURL(let urlString):
            return "InvalidURL: Target URL is invalid or malformed: \(urlString)"
        case .localOnlyRequiresLocalSource:
            return "LocalOnlyRequiresLocalSource: A local-only search request must use an on-device corpus source."
        case .localOnlyRequiresStaticLocalCrawl:
            return "LocalOnlyRequiresStaticLocalCrawl: Local-only corpus search cannot use a WebKit crawl that may load external resources."
        case .robotsDisallowed(let urlString):
            return "RobotsDisallowed: Crawl disallowed by robots.txt for URL: \(urlString)"
        case .rateLimited(let urlString, let retryAfter):
            return "RateLimited: Request rate limited for URL: \(urlString). Retry-After: \(retryAfter ?? 0)s"
        case .extractionFailed(let reason):
            return "ExtractionFailed: Struct extraction failed. Reason: \(reason)"
        case .networkFailure(let urlString, let statusCode):
            return "NetworkFailure: HTTP \(statusCode) for URL: \(urlString)"
        case .initializationFailed(let reason):
            return "InitializationFailed: The crawl store could not be initialized. Reason: \(reason)"
        case .timeoutBudgetExceeded:
            return "TimeoutBudgetExceeded: Overall crawl timeout budget reached."
        case .noResultsFound:
            return "NoResultsFound: Failed to scrape or extract any structured data from the target sources."
        }
    }
}
