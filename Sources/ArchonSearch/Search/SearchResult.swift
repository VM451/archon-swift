import Foundation

/// A single search result optimized for agent tool calls.
public struct SearchResult: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let snippet: String
    public let highlights: [String]
    
    public init(id: UUID = UUID(), url: URL, title: String, snippet: String, highlights: [String]) {
        self.id = id
        self.url = url
        self.title = title
        self.snippet = snippet
        self.highlights = highlights
    }
}
