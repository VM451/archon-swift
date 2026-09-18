import Testing
import Foundation
import ArchonCore
@testable import ArchonAgent

private struct HandoffState: AgentState {
    var value: String = ""
    var observedThreadId: String = ""
}

private actor RecordingAuditSink: ArchonAuditSink {
    var events: [ArchonAuditEvent] = []
    func record(_ event: ArchonAuditEvent) {
        events.append(event)
    }
}

@Suite("Agent Handoff Tests")
struct HandoffTests {
    private func passthroughGraph(tag: String) throws -> Graph<HandoffState> {
        let builder = GraphBuilder<HandoffState>()
        let node = ClosureNode<HandoffState>(id: "Worker") { state, context in
            var next = state
            next.value = tag
            next.observedThreadId = context.threadId
            return .state(next)
        }
        builder.addNode(node)
        builder.setEntryPoint("Worker")
        builder.addEdge(AgentEdge(from: "Worker", to: EndNode.id))
        return try builder.compile()
    }

    private func orchestrator() throws -> SwarmOrchestrator<HandoffState> {
        let orchestrator = SwarmOrchestrator<HandoffState>()
        orchestrator.register(agentName: "researcher", graph: try passthroughGraph(tag: "researched"))
        orchestrator.register(agentName: "writer", graph: try passthroughGraph(tag: "written"))
        return orchestrator
    }

    @Test("Successful handoff runs the target graph with a suffixed thread id")
    func successfulHandoff() async throws {
        let orchestrator = try orchestrator()
        let request = HandoffRequest(target: "writer", state: HandoffState(value: "draft"))
        let result = try await orchestrator.handoff(request, threadId: "root")
        #expect(result.value == "written")
        #expect(result.observedThreadId == "root.handoff.writer")
    }

    @Test("Unknown target fails closed with a typed error")
    func unknownTarget() async throws {
        let orchestrator = try orchestrator()
        let request = HandoffRequest(target: "ghost", state: HandoffState())
        do {
            _ = try await orchestrator.handoff(request, threadId: "root")
            Issue.record("Unknown target must throw.")
        } catch let error as HandoffError {
            #expect(error == .unknownTarget("ghost"))
            #expect(error.errorDescription?.contains("ghost") == true)
        }
    }

    @Test("Policy allowlist rejects unlisted targets")
    func notAllowed() async throws {
        let orchestrator = try orchestrator()
        let policy = HandoffPolicy(allowedTargets: ["researcher"])
        let request = HandoffRequest(target: "writer", state: HandoffState())
        do {
            _ = try await orchestrator.handoff(request, threadId: "root", policy: policy)
            Issue.record("Unlisted target must throw.")
        } catch let error as HandoffError {
            #expect(error == .notAllowed("writer"))
        }
        let allowed = try await orchestrator.handoff(
            HandoffRequest(target: "researcher", state: HandoffState()),
            threadId: "root",
            policy: policy
        )
        #expect(allowed.value == "researched")
    }

    @Test("Required reasons are enforced")
    func missingReason() async throws {
        let orchestrator = try orchestrator()
        let policy = HandoffPolicy(requireReason: true)
        do {
            _ = try await orchestrator.handoff(
                HandoffRequest(target: "writer", state: HandoffState()),
                threadId: "root",
                policy: policy
            )
            Issue.record("Missing reason must throw.")
        } catch let error as HandoffError {
            #expect(error == .missingReason("writer"))
        }
        let ok = try await orchestrator.handoff(
            HandoffRequest(target: "writer", state: HandoffState(), reason: "needs polish"),
            threadId: "root",
            policy: policy
        )
        #expect(ok.value == "written")
    }

    @Test("Chain depth is tracked through the thread id and bounded")
    func chainDepth() async throws {
        #expect(SwarmOrchestrator<HandoffState>.handoffDepth(of: "root") == 0)
        #expect(SwarmOrchestrator<HandoffState>.handoffDepth(of: "root.handoff.a") == 1)
        #expect(SwarmOrchestrator<HandoffState>.handoffDepth(of: "a.handoff.b.handoff.c") == 2)

        let orchestrator = try orchestrator()
        let policy = HandoffPolicy(maxChainDepth: 1)
        do {
            _ = try await orchestrator.handoff(
                HandoffRequest(target: "writer", state: HandoffState()),
                threadId: "root.handoff.researcher",
                policy: policy
            )
            Issue.record("Over-deep chain must throw.")
        } catch let error as HandoffError {
            #expect(error == .chainTooDeep(2))
        }
        let requestCapped = HandoffRequest(target: "writer", state: HandoffState(), maxChainDepth: 1)
        do {
            _ = try await orchestrator.handoff(requestCapped, threadId: "root.handoff.researcher")
            Issue.record("Request-level depth must throw.")
        } catch let error as HandoffError {
            #expect(error == .chainTooDeep(2))
        }
    }

    @Test("Cancellation mid-handoff surfaces a typed error")
    func cancellation() async throws {
        let builder = GraphBuilder<HandoffState>()
        let slow = ClosureNode<HandoffState>(id: "Slow") { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .unchanged
        }
        builder.addNode(slow)
        builder.setEntryPoint("Slow")
        builder.addEdge(AgentEdge(from: "Slow", to: EndNode.id))
        let orchestrator = SwarmOrchestrator<HandoffState>()
        orchestrator.register(agentName: "slow", graph: try builder.compile())

        let task = Task {
            try await orchestrator.handoff(
                HandoffRequest(target: "slow", state: HandoffState()),
                threadId: "root"
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled handoff must throw.")
        } catch let error as HandoffError {
            #expect(error == .cancelled)
        }
    }

    @Test("Handoff records audit outcomes")
    func auditTrail() async throws {
        let orchestrator = try orchestrator()
        let sink = RecordingAuditSink()
        _ = try await orchestrator.handoff(
            HandoffRequest(target: "writer", state: HandoffState()),
            threadId: "root",
            audit: sink
        )
        _ = try? await orchestrator.handoff(
            HandoffRequest(target: "ghost", state: HandoffState()),
            threadId: "root",
            audit: sink
        )
        let events = await sink.events
        #expect(events.count == 2)
        #expect(events[0].outcome == "completed")
        #expect(events[1].outcome == "unknown-target")
    }

    @Test("HandoffNode delegates to the orchestrator")
    func handoffNode() async throws {
        let orchestrator = try orchestrator()
        let builder = GraphBuilder<HandoffState>()
        builder.addNode(HandoffNode(
            id: "Delegate",
            orchestrator: orchestrator,
            target: "researcher",
            reason: "lookup"
        ))
        builder.setEntryPoint("Delegate")
        builder.addEdge(AgentEdge(from: "Delegate", to: EndNode.id))
        let graph = try builder.compile()
        let result = try await graph.invoke(initialState: HandoffState(), threadId: "parent")
        #expect(result.value == "researched")
        #expect(result.observedThreadId == "parent.handoff.researcher")
    }

    @Test("Agent-as-tool output is bounded and dispatcher-compatible")
    func agentAsToolBound() async throws {
        let builder = GraphBuilder<HandoffState>()
        let big = ClosureNode<HandoffState>(id: "Big") { state in
            var next = state
            next.value = String(repeating: "x", count: 50_000)
            return next
        }
        builder.addNode(big)
        builder.setEntryPoint("Big")
        builder.addEdge(AgentEdge(from: "Big", to: EndNode.id))
        let tool = AgentAsToolNode<HandoffState>(
            id: "summarizer-tool",
            childGraph: try builder.compile(),
            maxOutputCharacters: 100
        )

        let registry = ToolRegistry()
        #expect(registry.register(tool))
        let dispatcher = ToolDispatcher(
            registry: registry,
            authorizationPolicy: ToolAuthorizationPolicy(allowedToolNames: ["summarizer-tool"])
        )
        let message = await dispatcher.execute(call: ToolCall(name: "summarizer-tool", arguments: "{}"))
        #expect(message.content.hasSuffix("[output truncated]"))
        #expect(message.content.count <= 100 + "\n[output truncated]".count)

        let direct = try await tool.call(argumentsJSON: "{}")
        #expect(direct.hasSuffix("[output truncated]"))
    }
}
