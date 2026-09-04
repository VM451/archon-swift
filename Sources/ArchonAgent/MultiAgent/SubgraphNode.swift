import Foundation

/// Node that encapsulates an entire child graph, executing it as a self-contained sub-agent.
public struct SubgraphNode<ParentState: AgentState, ChildState: AgentState>: AgentNode {
    public let id: String
    public let description: String
    private let childGraph: Graph<ChildState>
    private let stateToChild: @Sendable (ParentState) -> ChildState
    private let childToState: @Sendable (inout ParentState, ChildState) -> Void

    public init(
        id: String,
        description: String = "",
        childGraph: Graph<ChildState>,
        stateToChild: @escaping @Sendable (ParentState) -> ChildState,
        childToState: @escaping @Sendable (inout ParentState, ChildState) -> Void
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.childGraph = childGraph
        self.stateToChild = stateToChild
        self.childToState = childToState
    }

    public func execute(state: ParentState, context: ExecutionContext) async throws -> NodeResult<ParentState> {
        let initialChildState = stateToChild(state)
        let finalChildState = try await childGraph.invoke(
            initialState: initialChildState,
            threadId: "\(context.threadId).subgraph.\(id)",
            metadata: context.metadata
        )

        var updatedParent = state
        childToState(&updatedParent, finalChildState)
        return .state(updatedParent)
    }
}

/// Executes multiple agent tasks concurrently using structured concurrency (`withThrowingTaskGroup`).
public struct ParallelNode<State: AgentState>: AgentNode {
    public let id: String
    public let description: String
    private let branches: [@Sendable (State, ExecutionContext) async throws -> State]
    private let reducer: @Sendable (inout State, [State]) -> Void

    public init(
        id: String,
        description: String = "",
        branches: [@Sendable (State, ExecutionContext) async throws -> State],
        reducer: @escaping @Sendable (inout State, [State]) -> Void
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.branches = branches
        self.reducer = reducer
    }

    public func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State> {
        let results = try await withThrowingTaskGroup(of: State.self) { group in
            for branch in branches {
                group.addTask {
                    try await branch(state, context)
                }
            }

            var branchStates: [State] = []
            for try await res in group {
                branchStates.append(res)
            }
            return branchStates
        }

        var next = state
        reducer(&next, results)
        return .state(next)
    }
}
