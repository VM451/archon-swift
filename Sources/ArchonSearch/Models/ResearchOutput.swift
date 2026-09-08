import Foundation

/// The structured response returned by research queries.
public struct ResearchOutput<T: ArchonGenerable & Codable & Sendable>: Sendable, Codable {
    public let data: T
    public let citations: [Citation]
    public let searchPathNodes: [ResearchNode]
    
    public init(data: T, citations: [Citation], searchPathNodes: [ResearchNode]) {
        self.data = data
        self.citations = citations
        self.searchPathNodes = searchPathNodes
    }
}

/// A node representation in the search visual mind-map graph.
public struct ResearchNode: Sendable, Codable, Hashable {
    public let urlString: String
    public let status: String
    public let priority: Int
    public let parentURLString: String?
    
    public init(urlString: String, status: String, priority: Int, parentURLString: String? = nil) {
        self.urlString = urlString
        self.status = status
        self.priority = priority
        self.parentURLString = parentURLString
    }
}
