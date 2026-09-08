import Foundation

/// Request payload sent to the Crawl4AI /crawl API endpoint.
public struct Crawl4AIRequest: Sendable, Codable, Hashable {
    public let urls: [String]
    public let priority: Int?
    public let wordCountThreshold: Int?
    public let cssSelector: String?
    public let magic: Bool?
    public let simulateUser: Bool?
    public let extractionStrategy: String?

    enum CodingKeys: String, CodingKey {
        case urls
        case priority
        case wordCountThreshold = "word_count_threshold"
        case cssSelector = "css_selector"
        case magic
        case simulateUser = "simulate_user"
        case extractionStrategy = "extraction_strategy"
    }

    public init(
        urls: [String],
        priority: Int? = 10,
        wordCountThreshold: Int? = nil,
        cssSelector: String? = nil,
        magic: Bool? = nil,
        simulateUser: Bool? = nil,
        extractionStrategy: String? = nil
    ) {
        self.urls = urls
        self.priority = priority
        self.wordCountThreshold = wordCountThreshold
        self.cssSelector = cssSelector
        self.magic = magic
        self.simulateUser = simulateUser
        self.extractionStrategy = extractionStrategy
    }

    public init(url: URL, options: CrawlOptions) {
        self.urls = [url.absoluteString]
        self.priority = options.priority
        self.wordCountThreshold = options.wordCountThreshold
        self.cssSelector = options.cssSelector
        self.magic = options.magic
        self.simulateUser = options.simulateUser
        self.extractionStrategy = options.extractionStrategy
    }
}
