import Foundation

/// On-device guardrail verdict. Deny-by-default: any denial fails the chain.
public enum GuardrailDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

/// A deterministic, on-device guardrail evaluated against agent state and trace.
public protocol AgentGuardrail<State>: Sendable {
    associatedtype State: AgentState
    var id: String { get }
    func check(state: State, trace: RunTrace) async throws -> GuardrailDecision
}

/// Typed guardrail denial.
public enum GuardrailError: Error, LocalizedError, Sendable, Equatable {
    case denied(id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .denied(let id, let reason):
            "Guardrail '\(id)' denied execution: \(reason)"
        }
    }
}

/// Runs guardrails in fixed registration order; the first denial wins.
public struct GuardrailChain<S: AgentState>: Sendable {
    private let guardrails: [any AgentGuardrail<S>]

    public init(_ guardrails: [any AgentGuardrail<S>] = []) {
        self.guardrails = guardrails
    }

    public var ids: [String] {
        guardrails.map(\.id)
    }

    /// Returns the first denial, or `.allow` when every guardrail allows.
    public func evaluate(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        for guardrail in guardrails {
            let verdict = try await guardrail.check(state: state, trace: trace)
            if case .deny = verdict {
                return verdict
            }
        }
        return .allow
    }

    /// Throws `GuardrailError.denied` on the first denial.
    public func enforce(state: S, trace: RunTrace) async throws {
        for guardrail in guardrails {
            if case .deny(let reason) = try await guardrail.check(state: state, trace: trace) {
                throw GuardrailError.denied(id: guardrail.id, reason: reason)
            }
        }
    }
}

/// Denies states whose extracted text exceeds a bounded character count.
public struct OutputLengthGuardrail<S: AgentState>: AgentGuardrail {
    public let id: String
    public let maxCharacters: Int
    private let textExtractor: @Sendable (S) -> String

    public init(
        id: String = "output-length",
        maxCharacters: Int,
        textExtractor: @escaping @Sendable (S) -> String = { state in
            if let data = try? JSONEncoder().encode(state) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: state)
        }
    ) {
        self.id = id
        self.maxCharacters = max(0, maxCharacters)
        self.textExtractor = textExtractor
    }

    public func check(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        let text = textExtractor(state)
        if text.count <= maxCharacters {
            return .allow
        }
        return .deny(reason: "Output length \(text.count) exceeds \(maxCharacters) characters.")
    }
}

/// Denies traces invoking tools the authorization policy would not dispatch.
/// Uses the registry so verdicts match `ToolDispatcher` exactly; without a
/// registry it falls back to the conservative name-only `allows(named:)` query.
public struct ToolAllowlistGuardrail<S: AgentState>: AgentGuardrail {
    public let id: String
    private let policy: ToolAuthorizationPolicy
    private let registry: ToolRegistry?

    public init(
        id: String = "tool-allowlist",
        policy: ToolAuthorizationPolicy,
        registry: ToolRegistry? = nil
    ) {
        self.id = id
        self.policy = policy
        self.registry = registry
    }

    public func check(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        let invoked = trace.spans.filter { $0.kind == .tool }.map(\.name)
        for name in invoked {
            if let registry, let tool = registry.tool(named: name) {
                if !policy.allows(tool) {
                    return .deny(reason: "Tool '\(name)' is not permitted by policy.")
                }
            } else if registry != nil {
                return .deny(reason: "Tool '\(name)' is not registered.")
            } else if !policy.allows(named: name) {
                return .deny(reason: "Tool '\(name)' is not permitted by policy.")
            }
        }
        return .allow
    }
}

/// Denies states whose extracted text contains a prohibited local pattern.
/// Patterns are bounded literal substrings matched case-insensitively.
public struct ProhibitedPatternGuardrail<S: AgentState>: AgentGuardrail {
    public static var maximumPatterns: Int { 64 }
    public static var maximumPatternLength: Int { 256 }

    public let id: String
    public let patterns: [String]
    private let textExtractor: @Sendable (S) -> String

    public init(
        id: String = "prohibited-pattern",
        patterns: [String],
        textExtractor: @escaping @Sendable (S) -> String = { state in
            if let data = try? JSONEncoder().encode(state) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: state)
        }
    ) {
        self.id = id
        self.patterns = Array(patterns.prefix(Self.maximumPatterns)).map {
            String($0.prefix(Self.maximumPatternLength))
        }
        self.textExtractor = textExtractor
    }

    public func check(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        let text = textExtractor(state)
        for pattern in patterns where !pattern.isEmpty {
            if text.localizedCaseInsensitiveContains(pattern) {
                return .deny(reason: "Prohibited pattern '\(pattern)' detected.")
            }
        }
        return .allow
    }
}

/// An agent-graph node enforcing a guardrail chain before and after a child closure.
public struct GuardrailNode<State: AgentState>: AgentNode {
    public let id: String
    public let description: String
    private let chain: GuardrailChain<State>
    private let child: @Sendable (State, ExecutionContext) async throws -> NodeResult<State>
    private let traceProvider: (@Sendable (State, ExecutionContext) -> RunTrace)?

    public init(
        id: String,
        description: String = "",
        chain: GuardrailChain<State>,
        traceProvider: (@Sendable (State, ExecutionContext) -> RunTrace)? = nil,
        child: @escaping @Sendable (State, ExecutionContext) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.description = description.isEmpty ? id : description
        self.chain = chain
        self.traceProvider = traceProvider
        self.child = child
    }

    public func execute(state: State, context: ExecutionContext) async throws -> NodeResult<State> {
        try await chain.enforce(state: state, trace: trace(for: state, context: context))
        let result = try await child(state, context)
        try await chain.enforce(state: postState(from: result, base: state), trace: trace(for: state, context: context))
        return result
    }

    private func trace(for state: State, context: ExecutionContext) -> RunTrace {
        if let traceProvider {
            return traceProvider(state, context)
        }
        return RunTrace(threadId: context.threadId, runId: context.runId, entryPoint: id)
    }

    private func postState(from result: NodeResult<State>, base: State) -> State {
        switch result {
        case .state(let next):
            return next
        case .mutate(let mutation):
            var copy = base
            mutation(&copy)
            return copy
        case .dictionary, .unchanged:
            return base
        }
    }
}
