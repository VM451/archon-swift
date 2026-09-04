import Foundation

/// Type of edge routing between graph nodes.
public enum EdgeType: Sendable, Equatable {
    case direct(target: String)
    case conditional
    case branch(mapping: [String: String], defaultTarget: String?)
}

/// Represents a directed transition from a source node to one or more target nodes.
public struct AgentEdge<State: AgentState>: Sendable {
    public let from: String
    public let type: EdgeType
    private let condition: (@Sendable (State, ExecutionContext) async throws -> String)?

    /// Direct edge from source to target.
    public init(from: String, to target: String) {
        self.from = from
        self.type = .direct(target: target)
        self.condition = nil
    }

    /// Dynamic conditional edge evaluated via a closure returning target NodeID.
    public init(
        from: String,
        condition: @escaping @Sendable (State) async throws -> String
    ) {
        self.from = from
        self.type = .conditional
        self.condition = { state, _ in try await condition(state) }
    }

    /// Dynamic conditional edge with access to ExecutionContext.
    public init(
        from: String,
        conditionWithContext: @escaping @Sendable (State, ExecutionContext) async throws -> String
    ) {
        self.from = from
        self.type = .conditional
        self.condition = conditionWithContext
    }

    /// Branch edge routing based on a discriminant key mapping to target node IDs.
    public init(
        from: String,
        path: @escaping @Sendable (State) async throws -> String,
        mapping: [String: String],
        defaultTarget: String? = nil
    ) {
        self.from = from
        self.type = .branch(mapping: mapping, defaultTarget: defaultTarget)
        self.condition = { state, _ in
            let key = try await path(state)
            if let matched = mapping[key] {
                return matched
            }
            if let fallback = defaultTarget {
                return fallback
            }
            throw GraphError.unresolvedBranch(from: from, key: key)
        }
    }

    /// Evaluates the edge and determines the next target node ID.
    public func resolveNext(state: State, context: ExecutionContext) async throws -> String {
        switch type {
        case .direct(let target):
            return target
        case .conditional, .branch:
            guard let condition = self.condition else {
                throw GraphError.missingCondition(nodeId: from)
            }
            return try await condition(state, context)
        }
    }
}
