import Foundation

/// The result of a deep, multi-step research run with web-grounded citations.
public struct DeepSearchOutput<T: ArchonGenerable & Codable & Sendable>: Sendable, Codable {
    public let originalQuery: String
    public let finalAnswer: T
    public let steps: [DeepResearchStep<T>]
    public let allCitations: [Citation]
    public let allSearchPathNodes: [ResearchNode]
    
    public init(originalQuery: String, finalAnswer: T, steps: [DeepResearchStep<T>], allCitations: [Citation], allSearchPathNodes: [ResearchNode]) {
        self.originalQuery = originalQuery
        self.finalAnswer = finalAnswer
        self.steps = steps
        self.allCitations = allCitations
        self.allSearchPathNodes = allSearchPathNodes
    }
}
