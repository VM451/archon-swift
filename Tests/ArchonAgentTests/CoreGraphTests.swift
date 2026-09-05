import Testing
import Foundation
@testable import ArchonAgent

struct SimpleAgentState: AgentState {
    var count: Int = 0
    var message: String = ""
}

@Suite("Core Graph Engine Tests")
struct CoreGraphTests {

    @Test("Direct edge execution from node A to node B to EndNode")
    func testDirectEdgeExecution() async throws {
        let builder = GraphBuilder<SimpleAgentState>()

        builder.addNode("increment", description: "Increments count") { state in
            var updated = state
            updated.count += 1
            return updated
        }

        builder.addNode("appendMsg", description: "Appends message") { state in
            var updated = state
            updated.message = "Count is \(updated.count)"
            return updated
        }

        builder.setEntryPoint("increment")
        builder.addEdge(from: "increment", to: "appendMsg")
        builder.addEdge(from: "appendMsg", to: EndNode.id)

        let graph = try builder.compile()
        let result = try await graph.invoke(initialState: SimpleAgentState())

        #expect(result.count == 1)
        #expect(result.message == "Count is 1")
    }

    @Test("Cyclic loop execution with conditional exit")
    func testCyclicLoopWithConditionalExit() async throws {
        let builder = GraphBuilder<SimpleAgentState>()

        builder.addNode("counter") { state in
            var s = state
            s.count += 1
            return s
        }

        builder.setEntryPoint("counter")
        builder.addConditionalEdge(from: "counter") { state in
            if state.count >= 5 {
                return EndNode.id
            } else {
                return "counter"
            }
        }

        let graph = try builder.compile()
        let result = try await graph.invoke(initialState: SimpleAgentState())

        #expect(result.count == 5)
    }

    @Test("Branch edge routing based on dictionary key")
    func testBranchEdgeRouting() async throws {
        let builder = GraphBuilder<SimpleAgentState>()

        builder.addNode("classifier") { state in
            var s = state
            s.message = "urgent"
            return s
        }

        builder.addNode("urgentHandler") { state in
            var s = state
            s.count = 911
            return s
        }

        builder.addNode("standardHandler") { state in
            var s = state
            s.count = 100
            return s
        }

        builder.setEntryPoint("classifier")
        builder.addBranchEdge(
            from: "classifier",
            path: { state in state.message },
            mapping: [
                "urgent": "urgentHandler",
                "standard": "standardHandler"
            ]
        )
        builder.addEdge(from: "urgentHandler", to: EndNode.id)
        builder.addEdge(from: "standardHandler", to: EndNode.id)

        let graph = try builder.compile()
        let result = try await graph.invoke(initialState: SimpleAgentState())

        #expect(result.count == 911)
    }

    @Test("Recursion limit guard prevents infinite loops")
    func testRecursionLimitGuard() async throws {
        let builder = GraphBuilder<SimpleAgentState>()

        builder.addNode("infinite") { state in
            var s = state
            s.count += 1
            return s
        }

        builder.setEntryPoint("infinite")
        builder.addEdge(from: "infinite", to: "infinite")

        let graph = try builder.compile(maxRecursionDepth: 10)

        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: SimpleAgentState())
        }
    }

    @Test("Graph compilation rejects missing nodes and missing entry points")
    func testGraphCompilationValidation() throws {
        let missingEntry = GraphBuilder<SimpleAgentState>()
        missingEntry.addNode("worker") { state in state }
        #expect(throws: GraphError.self) {
            try missingEntry.compile()
        }

        let missingTarget = GraphBuilder<SimpleAgentState>()
        missingTarget.addNode("worker") { state in state }
        missingTarget.setEntryPoint("worker")
        missingTarget.addEdge(from: "worker", to: "does-not-exist")
        #expect(throws: GraphError.self) {
            try missingTarget.compile()
        }
    }

    @Test("Graph compilation installs reducers before execution")
    func testReducerRegistrationIsSynchronous() async throws {
        let builder = GraphBuilder<SimpleAgentState>()
        builder.addNode("emit") { _, _ in
            NodeResult<SimpleAgentState>.dictionary(["count": "5"])
        }
        builder.addReducer(forKey: "count") { state, value in
            state.count += Int(value) ?? 0
        }
        builder.setEntryPoint("emit")
        builder.addEdge(from: "emit", to: EndNode.id)

        let graph = try builder.compile()
        let result = try await graph.invoke()
        #expect(result.count == 5)
    }
}
