import Foundation

/// A crawled and extracted web document.
public struct WebDocument: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let text: String
    public let markdown: String
    public let publishedAt: Date?
    public let metadata: [String: String]
    
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        text: String,
        markdown: String = "",
        publishedAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.text = text
        self.markdown = markdown
        self.publishedAt = publishedAt
        self.metadata = metadata
    }
}
