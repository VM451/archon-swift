import Foundation

/// Full page web contents with AI-optimized highlights for LLM context windows.
public struct ContentsResult: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let markdown: String
    public let html: String
    public let highlights: [String]
    
    public init(id: UUID = UUID(), url: URL, title: String, markdown: String, html: String, highlights: [String]) {
        self.id = id
        self.url = url
        self.title = title
        self.markdown = markdown
        self.html = html
        self.highlights = highlights
    }
}
