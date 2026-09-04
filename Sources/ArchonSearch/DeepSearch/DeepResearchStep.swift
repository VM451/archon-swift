import Foundation

/// A single step in a multi-step deep research workflow.
public struct DeepResearchStep<T: ArchonGenerable & Codable & Sendable>: Sendable, Codable {
    public let iteration: Int
    public let subQuery: String
    public let output: ResearchOutput<T>
    
    public init(iteration: Int, subQuery: String, output: ResearchOutput<T>) {
        self.iteration = iteration
        self.subQuery = subQuery
        self.output = output
    }
}
