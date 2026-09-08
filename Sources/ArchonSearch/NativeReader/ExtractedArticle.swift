import Foundation

/// A structured representation of extracted article content.
public struct ExtractedArticle: Sendable, Codable, Hashable {
    public let title: String
    public let author: String?
    public let publishedAt: Date?
    public let headings: [String]
    public let text: String
    public let markdown: String
    public let metadata: [String: String]

    public init(
        title: String,
        author: String? = nil,
        publishedAt: Date? = nil,
        headings: [String] = [],
        text: String,
        markdown: String,
        metadata: [String: String] = [:]
    ) {
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.headings = Array(headings.prefix(32))
        self.text = text
        self.markdown = markdown
        self.metadata = metadata
    }
}
