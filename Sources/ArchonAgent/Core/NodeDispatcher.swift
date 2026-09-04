import Foundation

/// Errors that can occur during graph and node execution.
public enum GraphError: Error, LocalizedError, Sendable, Equatable {
    case nodeNotFound(nodeId: String)
    case entryPointNotSet
    case recursionLimitExceeded(limit: Int, currentNodeId: String)
    case missingCondition(nodeId: String)
    case unresolvedBranch(from: String, key: String)
    case executionTimeout(nodeId: String, duration: TimeInterval)
    case graphHalted(reason: String)
    case interrupted(message: String, threadId: String)
    case stateDeserializationFailed(String)
    case zeroCloudViolation(String)
    case toolExecutionFailed(toolName: String, errorDescription: String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound(let id):
            return "Graph node '\(id)' was not found in the compiled graph."
        case .entryPointNotSet:
            return "Graph entry point has not been set. Call setEntryPoint(\"nodeId\") on GraphBuilder."
        case .recursionLimitExceeded(let limit, let current):
            return "Graph exceeded maximum recursion limit of \(limit) steps at node '\(current)'. Possible infinite cycle."
        case .missingCondition(let id):
            return "Conditional edge for node '\(id)' is missing an evaluation closure."
        case .unresolvedBranch(let from, let key):
            return "Branch edge from '\(from)' could not resolve key '\(key)' and no default target was provided."
        case .executionTimeout(let id, let duration):
            return "Node '\(id)' exceeded execution timeout limit of \(duration) seconds."
        case .graphHalted(let reason):
            return "Graph execution halted: \(reason)"
        case .interrupted(let message, let threadId):
            return "Graph execution interrupted on thread '\(threadId)': \(message)"
        case .stateDeserializationFailed(let msg):
            return "Failed to serialize/deserialize agent state: \(msg)"
        case .zeroCloudViolation(let reason):
            return "ZeroCloudMode Violation: Network request blocked: \(reason)"
        case .toolExecutionFailed(let tool, let err):
            return "Tool '\(tool)' execution failed: \(err)"
        }
    }
}

/// Actor-isolated dispatcher responsible for executing individual nodes safely,
/// applying state mutations, and logging execution metrics.
public actor NodeDispatcher<State: AgentState> {
    private var reducers: [String: @Sendable (inout State, String) -> Void] = [:]

    public init() {}

    /// Registers a custom state reducer for string-based dictionary key updates.
    public func registerReducer(forKey key: String, reducer: @escaping @Sendable (inout State, String) -> Void) {
        reducers[key] = reducer
    }

    /// Dispatches a node and produces the next state.
    public func dispatch<N: AgentNode>(
        node: N,
        state: State,
        context: ExecutionContext
    ) async throws -> (State, TimeInterval) where N.State == State {
        let startTime = Date()

        let result = try await node.execute(state: state, context: context)
        let duration = Date().timeIntervalSince(startTime)

        var nextState = state
        switch result {
        case .state(let full):
            nextState = full
        case .mutate(let mutateBlock):
            mutateBlock(&nextState)
        case .dictionary(let dict):
            for (k, v) in dict {
                if let reducer = reducers[k] {
                    reducer(&nextState, v)
                }
            }
        case .unchanged:
            break
        }

        return (nextState, duration)
    }
}
