import Foundation

/// A focused text passage extracted from a source document.
public struct SourcePassage: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let sourceID: UUID
    public let passageID: UUID
    public let text: String
    public let score: Double
    
    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        passageID: UUID = UUID(),
        text: String,
        score: Double = 0.0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.passageID = passageID
        self.text = text
        self.score = score
    }
}
