import Foundation

/// Fluent, single-owner builder to construct cyclic, stateful agent graphs.
///
/// A builder is intentionally not `Sendable`: it is mutable until `compile()`
/// creates an immutable, concurrently executable `Graph`.
public final class GraphBuilder<State: AgentState> {
    private var nodes: [String: any AgentNode<State>] = [:]
    private var edges: [String: AgentEdge<State>] = [:]
    private var entryPoint: String?
    private var reducers: [String: @Sendable (inout State, String) -> Void] = [:]
    private var validationIssues: [String] = []

    public init() {}

    /// Adds a node with a full result action.
    @discardableResult
    public func addNode(
        _ id: String,
        description: String = "",
        action: @escaping @Sendable (State, ExecutionContext) async throws -> NodeResult<State>
    ) -> Self {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append("Node identifiers must not be empty.")
        }
        if nodes[id] != nil {
            validationIssues.append("Node '\(id)' is registered more than once.")
        }
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
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append("Node identifiers must not be empty.")
        }
        if nodes[id] != nil {
            validationIssues.append("Node '\(id)' is registered more than once.")
        }
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
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append("Node identifiers must not be empty.")
        }
        if nodes[id] != nil {
            validationIssues.append("Node '\(id)' is registered more than once.")
        }
        let node = ClosureNode<State>(id: id, description: description, mutationAction: mutationAction)
        nodes[id] = node
        return self
    }

    /// Adds an existing AgentNode implementation.
    @discardableResult
    public func addNode<N: AgentNode>(_ node: N) -> Self where N.State == State {
        if node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append("Node identifiers must not be empty.")
        }
        if nodes[node.id] != nil {
            validationIssues.append("Node '\(node.id)' is registered more than once.")
        }
        nodes[node.id] = node
        return self
    }

    /// Connects two nodes with a direct static edge.
    @discardableResult
    public func addEdge(from: String, to target: String) -> Self {
        if edges[from] != nil {
            validationIssues.append("Only one outgoing edge may be registered for node '\(from)'.")
        }
        let edge = AgentEdge<State>(from: from, to: target)
        edges[from] = edge
        return self
    }

    /// Adds an AgentEdge instance.
    @discardableResult
    public func addEdge(_ edge: AgentEdge<State>) -> Self {
        if edges[edge.from] != nil {
            validationIssues.append("Only one outgoing edge may be registered for node '\(edge.from)'.")
        }
        edges[edge.from] = edge
        return self
    }

    /// Adds a dynamic conditional routing edge based on state.
    @discardableResult
    public func addConditionalEdge(
        from: String,
        condition: @escaping @Sendable (State) async throws -> String
    ) -> Self {
        if edges[from] != nil {
            validationIssues.append("Only one outgoing edge may be registered for node '\(from)'.")
        }
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
        if edges[from] != nil {
            validationIssues.append("Only one outgoing edge may be registered for node '\(from)'.")
        }
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
        if edges[from] != nil {
            validationIssues.append("Only one outgoing edge may be registered for node '\(from)'.")
        }
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

    /// Compiles and validates the graph into an executable Graph instance.
    public func compile(
        checkpointer: (any StateCheckpointer)? = nil,
        maxRecursionDepth: Int = 50
    ) throws -> Graph<State> {
        var issues = validationIssues
        guard let entryPoint else {
            issues.append(GraphError.entryPointNotSet.errorDescription ?? "An entry point is required.")
            throw GraphError.invalidGraph(Array(Set(issues)).sorted())
        }
        if maxRecursionDepth <= 0 {
            issues.append("maxRecursionDepth must be greater than zero.")
        }
        if nodes[entryPoint] == nil {
            issues.append("Entry point '\(entryPoint)' does not reference a registered node.")
        }

        for edge in edges.values {
            guard nodes[edge.from] != nil else {
                issues.append("Edge source '\(edge.from)' does not reference a registered node.")
                continue
            }
            for target in targets(of: edge) {
                if target != EndNode.id, nodes[target] == nil {
                    issues.append("Edge from '\(edge.from)' references missing node '\(target)'.")
                }
            }
        }

        if !issues.isEmpty {
            throw GraphError.invalidGraph(Array(Set(issues)).sorted())
        }

        let dispatcher = NodeDispatcher<State>(reducers: reducers)
        return Graph<State>(
            entryPoint: entryPoint,
            nodes: nodes,
            edges: edges,
            maxRecursionDepth: maxRecursionDepth,
            checkpointer: checkpointer,
            dispatcher: dispatcher
        )
    }

    private func targets(of edge: AgentEdge<State>) -> Set<String> {
        switch edge.type {
        case .direct(let target):
            return [target]
        case .conditional:
            return []
        case .branch(let mapping, let defaultTarget):
            var targets = Set(mapping.values)
            if let defaultTarget {
                targets.insert(defaultTarget)
            }
            return targets
        }
    }
}
