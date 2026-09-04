import Foundation

/// Represents a specialized sub-agent worker managed by a central supervisor.
public struct AgentWorker<State: AgentState>: Sendable {
    public let name: String
    public let roleDescription: String
    public let graph: Graph<State>

    public init(name: String, roleDescription: String, graph: Graph<State>) {
        self.name = name
        self.roleDescription = roleDescription
        self.graph = graph
    }
}

/// Orchestrates multi-agent routing where a central supervisor evaluates user tasks,
/// selects the most appropriate worker agent, and aggregates their outputs.
public final class SupervisorAgent<State: AgentState>: @unchecked Sendable {
    public let workers: [String: AgentWorker<State>]
    public let provider: any LLMProvider

    public init(workers: [AgentWorker<State>], provider: any LLMProvider = OnDeviceProvider.default) {
        var map: [String: AgentWorker<State>] = [:]
        for w in workers {
            map[w.name] = w
        }
        self.workers = map
        self.provider = provider
    }

    /// Evaluates which worker agent should process the current state.
    public func selectWorker(taskDescription: String) async throws -> AgentWorker<State> {
        let workerList = workers.values.map { "- \($0.name): \($0.roleDescription)" }.joined(separator: "\n")
        let prompt = [
            ChatMessage.system("You are a supervisor AI. Select the best worker for this task from:\n\(workerList)\nReturn only the worker name."),
            ChatMessage.user(taskDescription)
        ]

        let response = try await provider.generate(prompt: prompt)
        let chosen = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

        for (name, worker) in workers {
            if chosen.contains(name) || name.lowercased() == chosen.lowercased() {
                return worker
            }
        }

        guard let first = workers.values.first else {
            throw GraphError.graphHalted(reason: "No workers registered in SupervisorAgent.")
        }
        return first
    }

    /// Dispatches the task to the selected worker graph.
    public func run(initialState: State, taskDescription: String, threadId: String = UUID().uuidString) async throws -> State {
        let worker = try await selectWorker(taskDescription: taskDescription)
        return try await worker.graph.invoke(initialState: initialState, threadId: "\(threadId).\(worker.name)")
    }
}

/// Swarm Orchestrator managing dynamic agent-to-agent handoffs.
public final class SwarmOrchestrator<State: AgentState>: @unchecked Sendable {
    private var activeAgents: [String: Graph<State>] = [:]

    public init() {}

    public func register(agentName: String, graph: Graph<State>) {
        activeAgents[agentName] = graph
    }

    public func handoff(
        from sourceAgent: String,
        to targetAgent: String,
        state: State,
        threadId: String
    ) async throws -> State {
        guard let targetGraph = activeAgents[targetAgent] else {
            throw GraphError.nodeNotFound(nodeId: targetAgent)
        }
        return try await targetGraph.invoke(initialState: state, threadId: "\(threadId).handoff.\(targetAgent)")
    }
}
