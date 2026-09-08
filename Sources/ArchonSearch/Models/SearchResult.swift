import Foundation

/// A structured search result from search engine or local corpus discovery.
public struct SearchResult: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let snippet: String
    public let publishedAt: Date?
    public let score: Double?
    public let engine: String?
    public let highlights: [String]
    
    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        snippet: String,
        publishedAt: Date? = nil,
        score: Double? = nil,
        engine: String? = nil,
        highlights: [String] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.score = score
        self.engine = engine
        self.highlights = highlights
    }

    /// Convenience initializer maintaining backwards compatibility with earlier API.
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        snippet: String,
        highlights: [String] = [],
        publishedAt: Date? = nil,
        score: Double? = nil,
        engine: String? = nil
    ) {
        self.init(
            id: id,
            title: title,
            url: url,
            snippet: snippet,
            publishedAt: publishedAt,
            score: score,
            engine: engine,
            highlights: highlights
        )
    }
}
