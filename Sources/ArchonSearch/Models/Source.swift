import Foundation

/// An evidence source containing extracted passages.
public struct Source: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let passages: [SourcePassage]
    public let retrievedAt: Date
    
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        passages: [SourcePassage] = [],
        retrievedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.passages = passages
        self.retrievedAt = retrievedAt
    }
}
