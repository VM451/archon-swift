import Foundation

/// Represents a single evaluation test scenario with input prompts, expected behaviors, and assertions.
public struct EvalScenario<State: AgentState>: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let inputState: State
    public let expectedOutputSubstrings: [String]
    public let expectedToolCalls: [String]
    public let prohibitedToolCalls: [String]
    public let rubricCriteria: String?
    public let maxCostBudgetUSD: Double?
    public let maxLatencySeconds: TimeInterval?
    public let tags: [String]
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        inputState: State,
        expectedOutputSubstrings: [String] = [],
        expectedToolCalls: [String] = [],
        prohibitedToolCalls: [String] = [],
        rubricCriteria: String? = nil,
        maxCostBudgetUSD: Double? = nil,
        maxLatencySeconds: TimeInterval? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.inputState = inputState
        self.expectedOutputSubstrings = expectedOutputSubstrings
        self.expectedToolCalls = expectedToolCalls
        self.prohibitedToolCalls = prohibitedToolCalls
        self.rubricCriteria = rubricCriteria
        self.maxCostBudgetUSD = maxCostBudgetUSD
        self.maxLatencySeconds = maxLatencySeconds
        self.tags = tags
        self.metadata = metadata
    }
}

/// Collection of evaluation scenarios grouped into a regression test dataset.
public struct EvalDataset<State: AgentState>: Sendable {
    public let name: String
    public let scenarios: [EvalScenario<State>]

    public init(name: String, scenarios: [EvalScenario<State>]) {
        self.name = name
        self.scenarios = scenarios
    }

    /// Filters scenarios by specific tags.
    public func filtered(byTag tag: String) -> EvalDataset<State> {
        EvalDataset(name: "\(name) [\(tag)]", scenarios: scenarios.filter { $0.tags.contains(tag) })
    }
}
