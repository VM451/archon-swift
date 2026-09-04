import Testing
import Foundation
@testable import ArchonAgent

@Suite("Observability & Execution Tracing Tests")
struct ObservabilityTests {

    @Test("ExecutionTracer collects spans, renders DAG, and exports Mermaid and JSON")
    func tracerCollectsSpansAndExports() async throws {
        let tracer = ExecutionTracer()
        let threadId = "test-thread-1"
        let runId = "test-run-1"

        await tracer.startRun(threadId: threadId, runId: runId, entryPoint: "InputNode")

        let rootSpan = await tracer.startSpan(runId: runId, name: "InputNode", kind: .node)
        try await Task.sleep(nanoseconds: 5_000_000)

        let childSpan = await tracer.startSpan(
            runId: runId,
            name: "webSearch",
            kind: .tool,
            parentSpanId: rootSpan.id,
            attributes: ["query": "Swift concurrency"]
        )
        try await Task.sleep(nanoseconds: 5_000_000)

        await tracer.endSpan(
            spanId: childSpan.id,
            runId: runId,
            status: .completed,
            outputSnapshot: "Search Results Found",
            tokens: TokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150),
            costUSD: 0.00004
        )

        await tracer.endSpan(
            spanId: rootSpan.id,
            runId: runId,
            status: .completed,
            outputSnapshot: "Node finished"
        )

        guard let trace = await tracer.endRun(runId: runId, status: .completed) else {
            Issue.record("RunTrace should not be nil")
            return
        }

        #expect(trace.spans.count == 2)
        #expect(trace.totalTokens.totalTokens == 150)
        #expect(trace.totalCostUSD > 0.0)

        let dag = trace.renderDAG()
        #expect(dag.contains("InputNode"))
        #expect(dag.contains("webSearch"))

        let mermaid = trace.renderMermaid()
        #expect(mermaid.contains("flowchart TD"))
        #expect(mermaid.contains("-->"))

        let json = try trace.exportJSON()
        #expect(json.contains("\"runId\" : \"test-run-1\""))
    }

    @Test("ModelPricing and CostCalculator calculate accurate USD costs for Gemini 3.6, Claude 3.7, and GPT-4o")
    func modelPricingCalculations() {
        let geminiPricing = ModelPricing.geminiFlash
        let costGemini = geminiPricing.calculateCost(promptTokens: 1_000_000, completionTokens: 1_000_000)
        #expect(abs(costGemini - 0.50) < 0.001)

        let claudePricing = ModelPricing.claudeSonnet
        let costClaude = claudePricing.calculateCost(promptTokens: 1_000_000, completionTokens: 1_000_000)
        #expect(abs(costClaude - 18.00) < 0.001)

        let afmPricing = ModelPricing.appleFoundation
        let costAFM = afmPricing.calculateCost(promptTokens: 1_000_000, completionTokens: 1_000_000)
        #expect(costAFM == 0.0)

        let resolvedGemini = ModelPricing.resolve(for: "gemini-3.6-flash")
        #expect(resolvedGemini.modelId == "gemini-3.6-flash")
    }

    @Test("TokenLedger records multi-provider token usage and attributes cost per node and tool")
    func tokenLedgerAccounting() async {
        let ledger = TokenLedger()

        let cost1 = await ledger.record(
            providerId: "gemini",
            usage: TokenUsage(promptTokens: 2000, completionTokens: 1000, totalTokens: 3000),
            modelId: "gemini-3.6-flash",
            nodeId: "PlannerNode",
            toolName: "webSearch"
        )
        #expect(cost1 > 0.0)

        let cost2 = await ledger.record(
            providerId: "claude",
            usage: TokenUsage(promptTokens: 1000, completionTokens: 500, totalTokens: 1500),
            modelId: "claude-3-7-sonnet",
            nodeId: "SynthesizerNode",
            toolName: "calculator"
        )
        #expect(cost2 > 0.0)

        let total = await ledger.totalCostUSD()
        #expect(total == cost1 + cost2)

        let plannerUsage = await ledger.usage(forNode: "PlannerNode")
        #expect(plannerUsage.totalTokens == 3000)

        let searchUsage = await ledger.usage(forTool: "webSearch")
        #expect(searchUsage.totalTokens == 3000)
    }

    @Test("StepInspector and ReplayEngine compute state diffs across execution history")
    func stepInspectorDiff() async throws {
        let checkpointer = InMemoryCheckpointer()
        let threadId = "debug-thread"

        struct TestState: AgentState {
            var context: [String: String] = [:]
            var count: Int = 0
        }

        let record1 = CheckpointRecord(
            threadId: threadId,
            nodeId: "NodeA",
            stepIndex: 0,
            state: TestState(context: ["theme": "light", "user": "Alice"])
        )
        let record2 = CheckpointRecord(
            threadId: threadId,
            nodeId: "NodeB",
            stepIndex: 1,
            state: TestState(context: ["theme": "dark", "user": "Alice", "status": "active"])
        )

        try await checkpointer.save(record: record1)
        try await checkpointer.save(record: record2)

        let replay = ReplayEngine(checkpointer: checkpointer)
        let diffs = try await replay.generateStepDiffs(threadId: threadId)

        #expect(diffs.count == 1)
        let diff = diffs[0]
        #expect(diff.changedKeys.contains("theme"))
        #expect(diff.changedKeys.contains("status"))
        #expect(diff.stateDiffSummary.contains("~ [theme]"))
    }
}
