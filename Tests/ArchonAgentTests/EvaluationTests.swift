import Testing
import Foundation
@testable import ArchonAgent

@Suite("Agent Evaluation & A/B Testing Harness Tests")
struct EvaluationTests {

    struct EvalTestState: AgentState {
        var input: String = ""
        var output: String = ""
        var summary: String = ""
    }

    @Test("ContainsEvaluator passes when substrings are present")
    func containsEvaluatorPassing() async throws {
        let evaluator = ContainsEvaluator<EvalTestState>()
        let scenario = EvalScenario(
            name: "Greeting Test",
            inputState: EvalTestState(input: "Hello"),
            expectedOutputSubstrings: ["Archon", "Apple"]
        )

        let finalState = EvalTestState(output: "ArchonAgent runs on Apple platforms.")
        let trace = RunTrace(threadId: "t1", runId: "r1", entryPoint: "start")

        let score = try await evaluator.evaluate(scenario: scenario, finalState: finalState, trace: trace)
        #expect(score.isPassing)
        #expect(score.score == 1.0)
    }

    @Test("ToolCallSequenceEvaluator asserts expected and prohibited tool calls")
    func toolCallSequenceEvaluator() async throws {
        let evaluator = ToolCallSequenceEvaluator<EvalTestState>()
        let scenario = EvalScenario(
            name: "Search Flow",
            inputState: EvalTestState(),
            expectedToolCalls: ["webSearch", "calculator"],
            prohibitedToolCalls: ["dangerousShell"]
        )

        var trace = RunTrace(threadId: "t1", runId: "r1", entryPoint: "start")
        trace.spans = [
            TraceSpan(name: "webSearch", kind: .tool),
            TraceSpan(name: "calculator", kind: .tool)
        ]

        let score = try await evaluator.evaluate(scenario: scenario, finalState: EvalTestState(), trace: trace)
        #expect(score.isPassing)
        #expect(score.score == 1.0)
    }

    @Test("AgentEvalRunner runs a regression dataset against a Graph")
    func agentEvalRunnerEvaluation() async throws {
        let builder = GraphBuilder<EvalTestState>()
        let nodeA = ClosureNode<EvalTestState>(id: "FormatNode") { state in
            var updated = state
            updated.output = "Processed: \(state.input) by ArchonAgent"
            return updated
        }
        builder.addNode(nodeA)
        builder.setEntryPoint("FormatNode")
        builder.addEdge(AgentEdge(from: "FormatNode", to: EndNode.id))
        let graph = builder.compile()

        let dataset = EvalDataset<EvalTestState>(
            name: "Core Prompts Suite",
            scenarios: [
                EvalScenario(
                    name: "Scenario 1",
                    inputState: EvalTestState(input: "Alpha"),
                    expectedOutputSubstrings: ["Alpha", "ArchonAgent"]
                ),
                EvalScenario(
                    name: "Scenario 2",
                    inputState: EvalTestState(input: "Beta"),
                    expectedOutputSubstrings: ["Beta", "ArchonAgent"]
                )
            ]
        )

        let runner = AgentEvalRunner<EvalTestState>()
        let report = try await runner.run(graph: graph, dataset: dataset)

        #expect(report.totalScenarios == 2)
        #expect(report.passedScenarios == 2)
        #expect(report.passRatePercentage == 100.0)

        let summary = report.formattedSummary()
        #expect(summary.contains("Pass Rate: 100.0%"))
    }

    @Test("AgentABExperiment compares Variant A vs Variant B head-to-head")
    func agentABExperimentComparison() async throws {
        // Variant A
        let builderA = GraphBuilder<EvalTestState>()
        let nodeA = ClosureNode<EvalTestState>(id: "NodeA") { state in
            var copy = state
            copy.output = "Result: \(state.input)"
            return copy
        }
        builderA.addNode(nodeA)
        builderA.setEntryPoint("NodeA")
        builderA.addEdge(AgentEdge(from: "NodeA", to: EndNode.id))
        let graphA = builderA.compile()

        // Variant B (higher fidelity output)
        let builderB = GraphBuilder<EvalTestState>()
        let nodeB = ClosureNode<EvalTestState>(id: "NodeB") { state in
            var copy = state
            copy.output = "Result: \(state.input) (Enhanced with Archon Agentic Context)"
            return copy
        }
        builderB.addNode(nodeB)
        builderB.setEntryPoint("NodeB")
        builderB.addEdge(AgentEdge(from: "NodeB", to: EndNode.id))
        let graphB = builderB.compile()

        let dataset = EvalDataset<EvalTestState>(
            name: "Fidelity Benchmark",
            scenarios: [
                EvalScenario(
                    name: "Test Case",
                    inputState: EvalTestState(input: "Query"),
                    expectedOutputSubstrings: ["Enhanced"]
                )
            ]
        )

        let experiment = AgentABExperiment<EvalTestState>(
            name: "Prompt Refinement A/B",
            variantAName: "Prompt Baseline",
            variantBName: "Prompt Enhanced"
        )

        let comparison = try await experiment.compare(graphA: graphA, graphB: graphB, dataset: dataset)
        #expect(comparison.winningVariant == "Prompt Enhanced")
        #expect(comparison.reportB.passRatePercentage > comparison.reportA.passRatePercentage)

        let reportText = comparison.formattedReport()
        #expect(reportText.contains("Winner: 🏆 Prompt Enhanced"))
    }
}
