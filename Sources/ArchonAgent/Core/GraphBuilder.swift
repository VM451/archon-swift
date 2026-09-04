import Foundation

/// Fluent builder to construct cyclic, stateful multi-actor agent graphs.
public final class GraphBuilder<State: AgentState>: @unchecked Sendable {
    private var nodes: [String: any AgentNode<State>] = [:]
    private var edges: [String: AgentEdge<State>] = [:]
    private var entryPoint: String?
    private var reducers: [String: @Sendable (inout State, String) -> Void] = [:]

    public init() {}

    /// Adds a node with a full result action.
    @discardableResult
    public func addNode(
        _ id: String,
        description: String = "",
        action: @escaping @Sendable (State, ExecutionContext) async throws -> NodeResult<State>
    ) -> Self {
        let node = ClosureNode<State>(id: id, description: description, action: action)
        nodes[id] = node
        return self
    }

    /// Adds a node with a simple state transformation closure `(State) -> State`.
    @discardableResult
    public func addNode(
        _ id: String,
        description: String = "",
        simpleAction: @escaping @Sendable (State) async throws -> State
    ) -> Self {
        let node = ClosureNode<State>(id: id, description: description, simpleAction: simpleAction)
        nodes[id] = node
        return self
    }

    /// Adds a node with an in-place state mutation closure `(inout State) -> Void`.
    @discardableResult
    public func addNode(
        _ id: String,
        description: String = "",
        mutationAction: @escaping @Sendable (inout State) async throws -> Void
    ) -> Self {
        let node = ClosureNode<State>(id: id, description: description, mutationAction: mutationAction)
        nodes[id] = node
        return self
    }

    /// Adds an existing AgentNode implementation.
    @discardableResult
    public func addNode<N: AgentNode>(_ node: N) -> Self where N.State == State {
        nodes[node.id] = node
        return self
    }

    /// Connects two nodes with a direct static edge.
    @discardableResult
    public func addEdge(from: String, to target: String) -> Self {
        let edge = AgentEdge<State>(from: from, to: target)
        edges[from] = edge
        return self
    }

    /// Adds an AgentEdge instance.
    @discardableResult
    public func addEdge(_ edge: AgentEdge<State>) -> Self {
        edges[edge.from] = edge
        return self
    }

    /// Adds a dynamic conditional routing edge based on state.
    @discardableResult
    public func addConditionalEdge(
        from: String,
        condition: @escaping @Sendable (State) async throws -> String
    ) -> Self {
        let edge = AgentEdge<State>(from: from, condition: condition)
        edges[from] = edge
        return self
    }

    /// Adds a dynamic conditional routing edge with access to ExecutionContext.
    @discardableResult
    public func addConditionalEdge(
        from: String,
        conditionWithContext: @escaping @Sendable (State, ExecutionContext) async throws -> String
    ) -> Self {
        let edge = AgentEdge<State>(from: from, conditionWithContext: conditionWithContext)
        edges[from] = edge
        return self
    }

    /// Adds a branch routing edge mapping discriminator strings to target node IDs.
    @discardableResult
    public func addBranchEdge(
        from: String,
        path: @escaping @Sendable (State) async throws -> String,
        mapping: [String: String],
        defaultTarget: String? = nil
    ) -> Self {
        let edge = AgentEdge<State>(from: from, path: path, mapping: mapping, defaultTarget: defaultTarget)
        edges[from] = edge
        return self
    }

    /// Sets the initial entry point node for the graph execution.
    @discardableResult
    public func setEntryPoint(_ id: String) -> Self {
        self.entryPoint = id
        return self
    }

    /// Registers a custom field reducer for partial dictionary updates.
    @discardableResult
    public func addReducer(
        forKey key: String,
        reducer: @escaping @Sendable (inout State, String) -> Void
    ) -> Self {
        reducers[key] = reducer
        return self
    }

    /// Compiles the graph into an executable Graph instance.
    public func compile(
        checkpointer: (any StateCheckpointer)? = nil,
        maxRecursionDepth: Int = 50
    ) -> Graph<State> {
        let start = entryPoint ?? nodes.keys.first ?? StartNode.id
        let dispatcher = NodeDispatcher<State>()

        for (k, r) in reducers {
            Task {
                await dispatcher.registerReducer(forKey: k, reducer: r)
            }
        }

        return Graph<State>(
            entryPoint: start,
            nodes: nodes,
            edges: edges,
            maxRecursionDepth: maxRecursionDepth,
            checkpointer: checkpointer,
            dispatcher: dispatcher
        )
    }
}
