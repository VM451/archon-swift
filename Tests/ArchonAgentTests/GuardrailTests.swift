import Testing
import Foundation
@testable import ArchonAgent

private struct GuardrailState: AgentState {
    var output: String = ""
}

private struct DenyAll<S: AgentState>: AgentGuardrail {
    let id: String
    let reason: String
    func check(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        .deny(reason: reason)
    }
}

private struct AllowAll<S: AgentState>: AgentGuardrail {
    let id: String
    func check(state: S, trace: RunTrace) async throws -> GuardrailDecision {
        .allow
    }
}

private struct ReadOnlyProbeTool: Tool {
    let definition = ToolDefinition(name: "probe-read", description: "read-only probe")
    var authorizationRequirement: ToolAuthorizationRequirement { .readOnly }
    func call(argumentsJSON: String) async throws -> String { "ok" }
}

private struct WriteProbeTool: Tool {
    let definition = ToolDefinition(name: "probe-write", description: "write probe")
    func call(argumentsJSON: String) async throws -> String { "ok" }
}

private func toolTrace(names: [String]) -> RunTrace {
    var trace = RunTrace(threadId: "t", runId: "r", entryPoint: "start")
    trace.spans = names.map { TraceSpan(name: $0, kind: .tool) }
    return trace
}

@Suite("Agent Guardrail Tests")
struct GuardrailTests {
    @Test("First denial wins and order is fixed")
    func firstDenyWins() async throws {
        let chain = GuardrailChain<GuardrailState>([
            AllowAll(id: "first"),
            DenyAll<GuardrailState>(id: "second", reason: "blocked-two"),
            DenyAll<GuardrailState>(id: "third", reason: "blocked-three")
        ])
        let verdict = try await chain.evaluate(
            state: GuardrailState(),
            trace: RunTrace(threadId: "t", runId: "r", entryPoint: "s")
        )
        #expect(verdict == .deny(reason: "blocked-two"))
        do {
            try await chain.enforce(state: GuardrailState(), trace: RunTrace(threadId: "t", runId: "r", entryPoint: "s"))
            Issue.record("Denied chain must throw.")
        } catch let error as GuardrailError {
            #expect(error == .denied(id: "second", reason: "blocked-two"))
            #expect(error.errorDescription?.contains("second") == true)
        }
        #expect(chain.ids == ["first", "second", "third"])
    }

    @Test("Allow-all chain passes including the empty chain")
    func allowAllPasses() async throws {
        let chain = GuardrailChain<GuardrailState>([AllowAll(id: "a"), AllowAll(id: "b")])
        let trace = RunTrace(threadId: "t", runId: "r", entryPoint: "s")
        #expect(try await chain.evaluate(state: GuardrailState(), trace: trace) == .allow)
        try await chain.enforce(state: GuardrailState(), trace: trace)

        let empty = GuardrailChain<GuardrailState>()
        #expect(try await empty.evaluate(state: GuardrailState(), trace: trace) == .allow)
    }

    @Test("Output length guardrail bounds characters deterministically")
    func outputLength() async throws {
        let guardrail = OutputLengthGuardrail<GuardrailState>(maxCharacters: 5, textExtractor: \.output)
        let trace = RunTrace(threadId: "t", runId: "r", entryPoint: "s")
        #expect(try await guardrail.check(state: GuardrailState(output: "12345"), trace: trace) == .allow)
        let verdict = try await guardrail.check(state: GuardrailState(output: "123456"), trace: trace)
        #expect(verdict == .deny(reason: "Output length 6 exceeds 5 characters."))
    }

    @Test("Prohibited patterns deny case-insensitively with bounded lists")
    func prohibitedPatterns() async throws {
        let guardrail = ProhibitedPatternGuardrail<GuardrailState>(
            patterns: ["DROP TABLE", "", "rm -rf /"],
            textExtractor: \.output
        )
        let trace = RunTrace(threadId: "t", runId: "r", entryPoint: "s")
        #expect(try await guardrail.check(state: GuardrailState(output: "hello"), trace: trace) == .allow)
        let verdict = try await guardrail.check(state: GuardrailState(output: "please drop table users"), trace: trace)
        #expect(verdict == .deny(reason: "Prohibited pattern 'DROP TABLE' detected."))

        let many = ProhibitedPatternGuardrail<GuardrailState>(patterns: (0..<1000).map { "p\($0)" })
        #expect(many.patterns.count == ProhibitedPatternGuardrail<GuardrailState>.maximumPatterns)
    }

    @Test("Tool allowlist guardrail matches dispatcher verdicts")
    func dispatcherParity() async throws {
        let registry = ToolRegistry()
        registry.register(ReadOnlyProbeTool())
        registry.register(WriteProbeTool())
        let policy = ToolAuthorizationPolicy()
        let guardrail = ToolAllowlistGuardrail<GuardrailState>(policy: policy, registry: registry)
        let dispatcher = ToolDispatcher(registry: registry, authorizationPolicy: policy)
        let state = GuardrailState()

        let readTrace = toolTrace(names: ["probe-read"])
        #expect(try await guardrail.check(state: state, trace: readTrace) == .allow)
        let readMessage = await dispatcher.execute(call: ToolCall(name: "probe-read", arguments: "{}"))
        #expect(readMessage.content == "ok")

        let writeTrace = toolTrace(names: ["probe-write"])
        let verdict = try await guardrail.check(state: state, trace: writeTrace)
        #expect(verdict == .deny(reason: "Tool 'probe-write' is not permitted by policy."))
        let writeMessage = await dispatcher.execute(call: ToolCall(name: "probe-write", arguments: "{}"))
        #expect(writeMessage.content.contains("Authorization required"))

        let unknownTrace = toolTrace(names: ["missing"])
        let unknown = try await guardrail.check(state: state, trace: unknownTrace)
        #expect(unknown == .deny(reason: "Tool 'missing' is not registered."))
    }

    @Test("Name-only policy query stays conservative")
    func nameOnlyQuery() {
        #expect(ToolAuthorizationPolicy().allows(named: "probe-read") == false)
        #expect(ToolAuthorizationPolicy(allowedToolNames: ["probe-write"]).allows(named: "probe-write"))
        #expect(ToolAuthorizationPolicy.allowAll.allows(named: "anything"))
    }

    @Test("GuardrailNode enforces pre- and post-child checks")
    func guardrailNode() async throws {
        let denyLong = OutputLengthGuardrail<GuardrailState>(maxCharacters: 4, textExtractor: \.output)
        let chain = GuardrailChain([denyLong])

        let passthrough = GuardrailNode<GuardrailState>(id: "Checked", chain: chain) { state, _ in
            .state(state)
        }
        let context = ExecutionContext(threadId: "t")
        let ok = try await passthrough.execute(state: GuardrailState(output: "ok"), context: context)
        if case .state(let next) = ok {
            #expect(next.output == "ok")
        } else {
            Issue.record("Expected state result.")
        }
        do {
            _ = try await passthrough.execute(state: GuardrailState(output: "too long"), context: context)
            Issue.record("Pre-check denial must throw.")
        } catch let error as GuardrailError {
            #expect(error == .denied(id: "output-length", reason: "Output length 8 exceeds 4 characters."))
        }

        let escalating = GuardrailNode<GuardrailState>(id: "Escalating", chain: chain) { _, _ in
            .state(GuardrailState(output: "escalated output"))
        }
        do {
            _ = try await escalating.execute(state: GuardrailState(output: "ok"), context: context)
            Issue.record("Post-check denial must throw.")
        } catch is GuardrailError {
        }
    }
}
