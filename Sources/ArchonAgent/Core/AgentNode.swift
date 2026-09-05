import Foundation

/// Special Sentinel Nodes
public enum StartNode {
    public static let id: String = "__start__"
}

public enum EndNode {
    public static let id: String = "__end__"
}

/// The result returned by an AgentNode upon execution.
public enum NodeResult<State: AgentState>: Sendable {
    /// Overwrites the full state.
    case state(State)
    /// Applies an in-place mutation to the state.
    case mutate(@Sendable (inout State) -> Void)
    /// Emits partial state dictionary or key-value updates to be processed by registered Reducers.
    case dictionary([String: String])
    /// No state modification.
    case unchanged
}

/// Protocol defining an executable node within an agent graph.
public protocol AgentNode<State>: Sendable {
    associatedtype State: AgentState

    /// Unique identifier for this node within the graph.
    var id: String { get }

    /// Human-readable label or description.
    var description: String { get }

    /// Executes the node logic against the provided state and execution context.
    func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State>
}

/// A lightweight, closure-based concrete AgentNode implementation.
public struct ClosureNode<State: AgentState>: AgentNode {
    public let id: String
    public let description: String
    private let action: @Sendable (State, ExecutionContext) async throws -> NodeResult<State>

    public init(
        id: String,
        description: String = "",
        action: @escaping @Sendable (State, ExecutionContext) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.action = action
    }

    public init(
        id: String,
        description: String = "",
        simpleAction: @escaping @Sendable (State) async throws -> State
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.action = { state, _ in
            let newState = try await simpleAction(state)
            return .state(newState)
        }
    }

    public init(
        id: String,
        description: String = "",
        mutationAction: @escaping @Sendable (inout State) async throws -> Void
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.action = { state, _ in
            var copy = state
            try await mutationAction(&copy)
            return .state(copy)
        }
    }

    public func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State> {
        try await action(state, context)
    }
}
