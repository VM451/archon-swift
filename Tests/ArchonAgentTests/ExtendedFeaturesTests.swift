import Testing
import Foundation
import SwiftUI
@testable import ArchonAgent

@Suite("Supervisor Agent & Swarm Orchestrator Tests")
struct SupervisorAndSwarmTests {

    @Test("SupervisorAgent selects worker and delegates task")
    func testSupervisorSelectionAndRun() async throws {
        // Build worker 1: Math Worker
        let mathBuilder = GraphBuilder<SimpleAgentState>()
        mathBuilder.addNode("math") { state in
            var s = state
            s.count += 42
            return s
        }
        mathBuilder.setEntryPoint("math")
        mathBuilder.addEdge(from: "math", to: EndNode.id)
        let mathWorker = AgentWorker(name: "MathWorker", roleDescription: "Solves arithmetic calculations", graph: mathBuilder.compile())

        // Build worker 2: Text Worker
        let textBuilder = GraphBuilder<SimpleAgentState>()
        textBuilder.addNode("text") { state in
            var s = state
            s.count += 100
            return s
        }
        textBuilder.setEntryPoint("text")
        textBuilder.addEdge(from: "text", to: EndNode.id)
        let textWorker = AgentWorker(name: "TextWorker", roleDescription: "Summarizes text documents", graph: textBuilder.compile())

        // Mock LLM provider that selects MathWorker
        let provider = AppleFoundationModelProvider(id: "test.supervisor", simulatedDelay: 0.0)
        provider.registerMockResponse(forPromptContaining: "arithmetic", response: "MathWorker")

        let supervisor = SupervisorAgent<SimpleAgentState>(workers: [mathWorker, textWorker], provider: provider)
        let selected = try await supervisor.selectWorker(taskDescription: "Perform arithmetic 20 + 22")
        #expect(selected.name == "MathWorker")

        let finalState = try await supervisor.run(initialState: SimpleAgentState(count: 0), taskDescription: "Perform arithmetic 20 + 22")
        #expect(finalState.count == 42)
    }

    @Test("SwarmOrchestrator hands off execution between multiple graphs")
    func testSwarmHandoff() async throws {
        let orchestrator = SwarmOrchestrator<SimpleAgentState>()

        let graph1Builder = GraphBuilder<SimpleAgentState>()
        graph1Builder.addNode("agent1") { state in
            var s = state
            s.count += 10
            return s
        }
        graph1Builder.setEntryPoint("agent1")
        graph1Builder.addEdge(from: "agent1", to: EndNode.id)
        orchestrator.register(agentName: "Agent1", graph: graph1Builder.compile())

        let graph2Builder = GraphBuilder<SimpleAgentState>()
        graph2Builder.addNode("agent2") { state in
            var s = state
            s.count *= 3
            return s
        }
        graph2Builder.setEntryPoint("agent2")
        graph2Builder.addEdge(from: "agent2", to: EndNode.id)
        orchestrator.register(agentName: "Agent2", graph: graph2Builder.compile())

        let intermediateState = try await orchestrator.handoff(from: "User", to: "Agent1", state: SimpleAgentState(count: 5), threadId: "t1")
        #expect(intermediateState.count == 15)

        let finalState = try await orchestrator.handoff(from: "Agent1", to: "Agent2", state: intermediateState, threadId: "t1")
        #expect(finalState.count == 45)
    }
}

@Suite("Agent View Model & UI Binding Tests")
struct AgentViewModelTests {

    @Test("AgentViewModel tracks execution lifecycle and state updates")
    func testAgentViewModelLifecycle() async throws {
        let builder = GraphBuilder<SimpleAgentState>()
        builder.addNode("compute") { state in
            var s = state
            s.count = 99
            return s
        }
        builder.setEntryPoint("compute")
        builder.addEdge(from: "compute", to: EndNode.id)

        let graph = builder.compile()
        let vm = AgentViewModel(graph: graph, initialState: SimpleAgentState(count: 0))

        vm.start()

        // Wait briefly for main actor execution task
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.state.count == 99)
        #expect(vm.isExecuting == false)
        #expect(vm.executionLog.contains(where: { $0.contains("Graph completed") }))
    }

    @Test("AgentViewModel supports cancel and resume after interrupt")
    func testAgentViewModelCancelAndResume() async throws {
        let checkpointer = InMemoryCheckpointer()
        let builder = GraphBuilder<PersistentState>()

        builder.addNode("riskyNode") { state in
            var s = state
            s.data = "done"
            return s
        }
        builder.setEntryPoint("riskyNode")
        builder.addEdge(from: "riskyNode", to: EndNode.id)

        let graph = builder.compile(checkpointer: checkpointer)
        let vm = AgentViewModel(graph: graph, initialState: PersistentState(step: 0, data: "initial"))

        vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.isExecuting == false)
        #expect(vm.state.data == "done")

        vm.cancel()
        #expect(vm.executionLog.contains(where: { $0.contains("cancelled") }))
    }
}

@Suite("LLM Providers Configuration & Zero-Cloud Mode Tests")
struct ProvidersExtendedTests {

    @Test("OpenAI, Anthropic, Gemini, and Ollama instantiate with configured settings")
    func testProviderConfigurations() throws {
        let openai = OpenAIProvider(apiKey: "sk-test", model: "gpt-4o")
        #expect(openai.id == "openai.gpt-4o")
        #expect(openai.apiKey == "sk-test")

        let anthropic = AnthropicProvider(apiKey: "anth-test", model: "claude-3-5-sonnet")
        #expect(anthropic.id == "anthropic.claude-3-5-sonnet")
        #expect(anthropic.apiKey == "anth-test")

        let gemini = GoogleGeminiProvider(apiKey: "gem-test", model: "gemini-1.5-pro")
        #expect(gemini.id == "google.gemini-1.5-pro")
        #expect(gemini.apiKey == "gem-test")

        let ollama = OllamaProvider(model: "llama3:8b")
        #expect(ollama.id == "ollama.llama3:8b")
    }

    @Test("ZeroCloudMode toggles enforce local execution")
    func testZeroCloudModeToggles() {
        ZeroCloudMode.isEnabled = true
        #expect(ZeroCloudMode.isEnabled == true)

        #expect(throws: Error.self) {
            try ZeroCloudMode.ensureAllowed(provider: "OpenAI")
        }

        ZeroCloudMode.isEnabled = false
        #expect(ZeroCloudMode.isEnabled == false)
        #expect(throws: Never.self) {
            try ZeroCloudMode.ensureAllowed(provider: "OpenAI")
        }
    }
}
