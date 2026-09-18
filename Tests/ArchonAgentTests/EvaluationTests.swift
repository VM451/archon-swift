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
        let graph = try builder.compile()

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
        let graphA = try builderA.compile()

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
        let graphB = try builderB.compile()

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

@Suite("Agent Evaluation Budget Metrics Tests")
struct EvalBudgetMetricsTests {
    struct BudgetState: AgentState {
        var input: String = ""
        var output: String = ""
    }

    private func toolTrace(names: [String], totalTokens: Int = 0) -> RunTrace {
        var trace = RunTrace(threadId: "t", runId: "r", entryPoint: "start")
        trace.spans = names.map { TraceSpan(name: $0, kind: .tool) }
        trace.totalTokens = TokenUsage(totalTokens: totalTokens)
        return trace
    }

    private func scenario(id: String, input: String) -> EvalScenario<BudgetState> {
        EvalScenario(id: id, name: id, inputState: BudgetState(input: input))
    }

    private func echoGraph() throws -> Graph<BudgetState> {
        let builder = GraphBuilder<BudgetState>()
        let node = ClosureNode<BudgetState>(id: "Echo") { state in
            var next = state
            next.output = "out:\(state.input)"
            return next
        }
        builder.addNode(node)
        builder.setEntryPoint("Echo")
        builder.addEdge(AgentEdge(from: "Echo", to: EndNode.id))
        return try builder.compile()
    }

    @Test("Tool order evaluator accepts ordered subsequences only")
    func toolOrder() async throws {
        let evaluator = ToolOrderEvaluator<BudgetState>(expectedOrder: ["fetch", "summarize"])
        let scenario = self.scenario(id: "s", input: "x")
        let passing = try await evaluator.evaluate(
            scenario: scenario, finalState: BudgetState(),
            trace: toolTrace(names: ["fetch", "other", "summarize"])
        )
        #expect(passing.isPassing)
        let failing = try await evaluator.evaluate(
            scenario: scenario, finalState: BudgetState(),
            trace: toolTrace(names: ["summarize", "fetch"])
        )
        #expect(!failing.isPassing)
        #expect(failing.score < 1.0)
        let empty = ToolOrderEvaluator<BudgetState>(expectedOrder: [])
        let vacuous = try await empty.evaluate(
            scenario: scenario, finalState: BudgetState(), trace: toolTrace(names: [])
        )
        #expect(vacuous.isPassing)
    }

    @Test("Token budget evaluator enforces RunTrace totals")
    func tokenBudget() async throws {
        let evaluator = TokenBudgetEvaluator<BudgetState>(maxTokens: 100)
        let scenario = self.scenario(id: "s", input: "x")
        let passing = try await evaluator.evaluate(
            scenario: scenario, finalState: BudgetState(), trace: toolTrace(names: [], totalTokens: 100)
        )
        #expect(passing.isPassing)
        let failing = try await evaluator.evaluate(
            scenario: scenario, finalState: BudgetState(), trace: toolTrace(names: [], totalTokens: 101)
        )
        #expect(!failing.isPassing)
    }

    @Test("Per-scenario timeout records a typed failure")
    func perScenarioTimeout() async throws {
        let builder = GraphBuilder<BudgetState>()
        let slow = ClosureNode<BudgetState>(id: "Slow") { state in
            try await Task.sleep(for: .seconds(30))
            var next = state
            next.output = "late"
            return next
        }
        builder.addNode(slow)
        builder.setEntryPoint("Slow")
        builder.addEdge(AgentEdge(from: "Slow", to: EndNode.id))
        let graph = try builder.compile()
        let dataset = EvalDataset(name: "Timeout", scenarios: [scenario(id: "slow", input: "x")])

        let runner = AgentEvalRunner<BudgetState>(metrics: [])
        let report = try await runner.run(
            graph: graph, dataset: dataset,
            options: EvalRunOptions(perScenarioTimeout: .milliseconds(50))
        )
        #expect(report.totalScenarios == 1)
        #expect(report.passedScenarios == 0)
        let timeoutScore = try #require(report.scenarioResults.first?.scores.first)
        #expect(timeoutScore.metricName == "ScenarioTimeout")
        #expect(!timeoutScore.isPassing)
        #expect(timeoutScore.reason.contains("slow"))
    }

    @Test("Seeded runs are deterministic and fail-fast short-circuits")
    func seededDeterminismAndFailFast() async throws {
        let graph = try echoGraph()
        let dataset = EvalDataset(name: "Seeded", scenarios: [
            scenario(id: "a", input: "1"),
            scenario(id: "b", input: "2"),
            scenario(id: "c", input: "3")
        ])
        let runner = AgentEvalRunner<BudgetState>(metrics: [ContainsEvaluator()])
        let first = try await runner.run(graph: graph, dataset: dataset, options: EvalRunOptions(seed: 42))
        let second = try await runner.run(graph: graph, dataset: dataset, options: EvalRunOptions(seed: 42))
        #expect(first.scenarioResults.map(\.scenarioId) == second.scenarioResults.map(\.scenarioId))

        let strict = EvalDataset(name: "Strict", scenarios: [
            EvalScenario(
                id: "fail", name: "fail", inputState: BudgetState(input: "x"),
                expectedOutputSubstrings: ["never-present"]
            ),
            scenario(id: "never-runs", input: "y")
        ])
        let failFast = try await runner.run(
            graph: graph, dataset: strict, options: EvalRunOptions(failFast: true)
        )
        #expect(failFast.scenarioResults.map(\.scenarioId) == ["fail"])
        let full = try await runner.run(graph: graph, dataset: strict)
        #expect(full.scenarioResults.count == 2)
    }

    @Test("Report JSON round-trips with stable key order")
    func jsonRoundTrip() async throws {
        let graph = try echoGraph()
        let dataset = EvalDataset(name: "JSON", scenarios: [
            scenario(id: "b", input: "2"),
            scenario(id: "a", input: "1")
        ])
        let runner = AgentEvalRunner<BudgetState>(metrics: [ContainsEvaluator()])
        let report = try await runner.run(graph: graph, dataset: dataset)
        let data = try report.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"datasetName\":\"JSON\""))
        let again = try report.jsonData()
        #expect(data == again)
        let decoded = try JSONDecoder().decode(EvalReportJSON.self, from: data)
        #expect(decoded.datasetName == "JSON")
        #expect(decoded.scenarioResults.map(\.scenarioId) == ["a", "b"])
    }
}

private struct EvalReportJSON: Decodable {
    struct Scenario: Decodable {
        let scenarioId: String
    }
    let datasetName: String
    let scenarioResults: [Scenario]
}
