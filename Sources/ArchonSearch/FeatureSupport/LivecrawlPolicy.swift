import Foundation

/// The livecrawl policy that controls how page content is retrieved.
public enum LivecrawlPolicy: Sendable, Codable, Hashable {
    /// Fast, static HTTP fetch with light DOM cleaning.
    /// Best for low-latency search tool calls.
    case fast
    /// Full WebKit rendering with stealth behavior, JS execution and OCR fallback.
    /// Best for complete page contents and deep research.
    case full(scrapeConfig: ScrapeConfiguration)
}
