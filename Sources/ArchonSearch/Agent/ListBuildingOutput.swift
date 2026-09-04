import Foundation

/// Result of an agentic list-building and enrichment run.
public struct ListBuildingOutput<T: ArchonGenerable & Codable & Sendable>: Sendable, Codable {
    public let query: String
    public let items: [T]
    public let citations: [Citation]
    
    public init(query: String, items: [T], citations: [Citation]) {
        self.query = query
        self.items = items
        self.citations = citations
    }
}
