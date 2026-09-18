import ArchonCore
import Foundation

/// A typed request to hand execution off to another registered agent.
public struct HandoffRequest<S: AgentState>: Sendable {
    public let target: String
    public let state: S
    public let reason: String
    public let maxChainDepth: Int

    public init(target: String, state: S, reason: String = "", maxChainDepth: Int = 5) {
        self.target = target
        self.state = state
        self.reason = reason
        self.maxChainDepth = max(0, maxChainDepth)
    }
}

/// Fail-closed policy governing agent handoffs.
public struct HandoffPolicy: Sendable {
    /// Allowed handoff targets. `nil` permits any registered agent.
    public let allowedTargets: Set<String>?
    public let maxChainDepth: Int
    public let requireReason: Bool

    public init(allowedTargets: Set<String>? = nil, maxChainDepth: Int = 5, requireReason: Bool = false) {
        self.allowedTargets = allowedTargets
        self.maxChainDepth = max(0, maxChainDepth)
        self.requireReason = requireReason
    }
}

/// Typed handoff failures. Unknown targets and policy violations fail closed.
public enum HandoffError: Error, LocalizedError, Sendable, Equatable {
    case unknownTarget(String)
    case notAllowed(String)
    case chainTooDeep(Int)
    case missingReason(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unknownTarget(let target):
            "Handoff target is not registered: \(target)"
        case .notAllowed(let target):
            "Handoff target is not permitted by policy: \(target)"
        case .chainTooDeep(let depth):
            "Handoff chain depth \(depth) exceeds the maximum."
        case .missingReason(let target):
            "Handoff to \(target) requires a reason."
        case .cancelled:
            "The handoff was cancelled."
        }
    }
}

public extension SwarmOrchestrator {
    /// Chain-depth marker appended to thread identifiers on every handoff.
    static var handoffThreadMarker: String { ".handoff." }

    /// Counts completed handoffs encoded in a thread identifier.
    static func handoffDepth(of threadId: String) -> Int {
        guard !threadId.isEmpty else { return 0 }
        return max(0, threadId.components(separatedBy: handoffThreadMarker).count - 1)
    }

    /// Hands execution to `request.target` under `policy`, tracking chain depth
    /// through the thread identifier and checking for cancellation.
    func handoff(
        _ request: HandoffRequest<State>,
        threadId: String,
        policy: HandoffPolicy = HandoffPolicy(),
        audit: (any ArchonAuditSink)? = nil
    ) async throws -> State {
        do {
            try Task.checkCancellation()
        } catch {
            throw HandoffError.cancelled
        }
        guard let targetGraph = activeAgents[request.target] else {
            await audit?.record(ArchonAuditEvent(
                category: "agent.handoff", action: request.target,
                outcome: "unknown-target", metadata: ["thread-id": threadId]
            ))
            throw HandoffError.unknownTarget(request.target)
        }
        if let allowed = policy.allowedTargets, !allowed.contains(request.target) {
            await audit?.record(ArchonAuditEvent(
                category: "agent.handoff", action: request.target,
                outcome: "denied", metadata: ["thread-id": threadId]
            ))
            throw HandoffError.notAllowed(request.target)
        }
        if policy.requireReason, request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HandoffError.missingReason(request.target)
        }
        let effectiveMax = min(policy.maxChainDepth, request.maxChainDepth)
        let nextDepth = Self.handoffDepth(of: threadId) + 1
        guard nextDepth <= effectiveMax else {
            await audit?.record(ArchonAuditEvent(
                category: "agent.handoff", action: request.target,
                outcome: "chain-too-deep",
                metadata: ["thread-id": threadId, "depth": String(nextDepth)]
            ))
            throw HandoffError.chainTooDeep(nextDepth)
        }
        let childThreadId = "\(threadId)\(Self.handoffThreadMarker)\(request.target)"
        do {
            try Task.checkCancellation()
            let result = try await targetGraph.invoke(initialState: request.state, threadId: childThreadId)
            try Task.checkCancellation()
            await audit?.record(ArchonAuditEvent(
                category: "agent.handoff", action: request.target,
                outcome: "completed",
                metadata: ["thread-id": threadId, "depth": String(nextDepth)]
            ))
            return result
        } catch is CancellationError {
            throw HandoffError.cancelled
        } catch let error as HandoffError {
            throw error
        }
    }
}

/// An agent-graph node that hands execution to a registered swarm target.
public struct HandoffNode<State: AgentState>: AgentNode {
    public let id: String
    public let description: String
    private let orchestrator: SwarmOrchestrator<State>
    private let target: String
    private let policy: HandoffPolicy
    private let reason: String
    private let maxChainDepth: Int

    public init(
        id: String,
        description: String = "",
        orchestrator: SwarmOrchestrator<State>,
        target: String,
        policy: HandoffPolicy = HandoffPolicy(),
        reason: String = "",
        maxChainDepth: Int = 5
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.orchestrator = orchestrator
        self.target = target
        self.policy = policy
        self.reason = reason
        self.maxChainDepth = maxChainDepth
    }

    public func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State> {
        let request = HandoffRequest(target: target, state: state, reason: reason, maxChainDepth: maxChainDepth)
        let next = try await orchestrator.handoff(request, threadId: context.threadId, policy: policy)
        return .state(next)
    }
}

/// Wraps a child graph so it can be invoked either as a graph node or as a
/// `ToolDispatcher`-compatible tool. Tool output is bounded to `maxOutputCharacters`.
public struct AgentAsToolNode<State: AgentState>: AgentNode, Tool {
    public let id: String
    public let description: String
    public let definition: ToolDefinition
    public let authorizationRequirement: ToolAuthorizationRequirement = .explicitApproval
    private let childGraph: Graph<State>
    private let maxOutputCharacters: Int

    public init(
        id: String,
        description: String = "",
        toolName: String? = nil,
        childGraph: Graph<State>,
        maxOutputCharacters: Int = 8_000
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.childGraph = childGraph
        self.maxOutputCharacters = max(0, maxOutputCharacters)
        self.definition = ToolDefinition(
            name: toolName ?? id,
            description: description.isEmpty ? id : description
        )
    }

    public func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State> {
        try Task.checkCancellation()
        let result = try await childGraph.invoke(
            initialState: state,
            threadId: "\(context.threadId).agent-tool.\(id)",
            metadata: context.metadata
        )
        return .state(result)
    }

    public func call(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let initial: State
        if let data = argumentsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            initial = decoded
        } else {
            initial = State()
        }
        let result = try await childGraph.invoke(initialState: initial, threadId: "agent-tool.\(id)")
        let encoded: String
        if let data = try? JSONEncoder().encode(result) {
            encoded = String(decoding: data, as: UTF8.self)
        } else {
            encoded = String(describing: result)
        }
        if encoded.count <= maxOutputCharacters {
            return encoded
        }
        return String(encoded.prefix(maxOutputCharacters)) + "\n[output truncated]"
    }
}
