import Foundation

/// Detailed evaluation outcome for a single scenario.
public struct ScenarioEvalResult<State: AgentState>: Sendable {
    public let scenarioId: String
    public let scenarioName: String
    public let finalState: State
    public let trace: RunTrace
    public let scores: [EvalScore]
    public let isPassing: Bool
    public let duration: TimeInterval
    public let costUSD: Double

    public init(
        scenarioId: String,
        scenarioName: String,
        finalState: State,
        trace: RunTrace,
        scores: [EvalScore]
    ) {
        self.scenarioId = scenarioId
        self.scenarioName = scenarioName
        self.finalState = finalState
        self.trace = trace
        self.scores = scores
        self.isPassing = scores.allSatisfy(\.isPassing)
        self.duration = trace.totalDuration ?? 0.0
        self.costUSD = trace.totalCostUSD
    }
}

/// Comprehensive evaluation report summarizing dataset-wide agent performance.
public struct EvalReport<State: AgentState>: Sendable {
    public let datasetName: String
    public let totalScenarios: Int
    public let passedScenarios: Int
    public let passRatePercentage: Double
    public let averageScore: Double
    public let averageDuration: TimeInterval
    public let totalTokens: TokenUsage
    public let totalCostUSD: Double
    public let scenarioResults: [ScenarioEvalResult<State>]
    public let timestamp: Date

    public init(
        datasetName: String,
        scenarioResults: [ScenarioEvalResult<State>]
    ) {
        self.datasetName = datasetName
        self.scenarioResults = scenarioResults
        self.totalScenarios = scenarioResults.count
        self.passedScenarios = scenarioResults.filter(\.isPassing).count
        self.passRatePercentage = totalScenarios > 0 ? (Double(passedScenarios) / Double(totalScenarios)) * 100.0 : 0.0

        let allScores = scenarioResults.flatMap(\.scores).map(\.score)
        self.averageScore = allScores.isEmpty ? 0.0 : allScores.reduce(0.0, +) / Double(allScores.count)

        let durations = scenarioResults.map(\.duration)
        self.averageDuration = durations.isEmpty ? 0.0 : durations.reduce(0.0, +) / Double(durations.count)

        var prompt = 0
        var completion = 0
        var total = 0
        var cost: Double = 0.0

        for r in scenarioResults {
            prompt += r.trace.totalTokens.promptTokens
            completion += r.trace.totalTokens.completionTokens
            total += r.trace.totalTokens.totalTokens
            cost += r.costUSD
        }

        self.totalTokens = TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
        self.totalCostUSD = cost
        self.timestamp = Date()
    }

    /// Formats a clean ASCII summary table of the evaluation results.
    public func formattedSummary() -> String {
        var lines: [String] = []
        lines.append("================================================================================")
        lines.append("ARCHON AGENT EVALUATION REPORT: \(datasetName)")
        lines.append("Pass Rate: \(String(format: "%.1f", passRatePercentage))% (\(passedScenarios)/\(totalScenarios)) | Avg Score: \(String(format: "%.2f", averageScore)) | Avg Latency: \(String(format: "%.3f", averageDuration))s")
        lines.append("Total Tokens: \(totalTokens.totalTokens) | Total Cost: $\(String(format: "%.5f", totalCostUSD))")
        lines.append("--------------------------------------------------------------------------------")

        for r in scenarioResults {
            let status = r.isPassing ? "✅ PASS" : "❌ FAIL"
            lines.append("\(status) | [\(r.scenarioName)] (\(String(format: "%.3f", r.duration))s, $\(String(format: "%.5f", r.costUSD)))")
            for score in r.scores {
                lines.append("   - \(score.metricName): \(score.isPassing ? "PASS" : "FAIL") (score: \(String(format: "%.2f", score.score))) \(score.reason)")
            }
        }
        lines.append("================================================================================")
        return lines.joined(separator: "\n")
    }
}

/// Test runner that executes regression evaluation datasets against agent graphs.
public struct AgentEvalRunner<State: AgentState>: Sendable {
    public let metrics: [any EvalMetric<State>]

    public init(metrics: [any EvalMetric<State>] = [ContainsEvaluator(), ToolCallSequenceEvaluator(), LatencyEvaluator(), CostBudgetEvaluator()]) {
        self.metrics = metrics
    }

    /// Evaluates an agent graph across a dataset.
    public func run(
        graph: Graph<State>,
        dataset: EvalDataset<State>,
        tracer: ExecutionTracer = ExecutionTracer()
    ) async throws -> EvalReport<State> {
        var scenarioResults: [ScenarioEvalResult<State>] = []

        for scenario in dataset.scenarios {
            let threadId = "eval-\(scenario.id)"
            let runId = UUID().uuidString

            await tracer.startRun(threadId: threadId, runId: runId, entryPoint: graph.entryPoint, metadata: scenario.metadata)
            let rootSpan = await tracer.startSpan(runId: runId, name: scenario.name, kind: .graph)

            var finalState = scenario.inputState
            var capturedError: String? = nil

            do {
                finalState = try await graph.invoke(
                    initialState: scenario.inputState,
                    threadId: threadId,
                    metadata: scenario.metadata
                )
            } catch {
                capturedError = error.localizedDescription
            }

            await tracer.endSpan(
                spanId: rootSpan.id,
                runId: runId,
                status: capturedError == nil ? .completed : .failed,
                errorMessage: capturedError
            )
            let trace = await tracer.endRun(runId: runId, status: capturedError == nil ? .completed : .failed) ?? RunTrace(threadId: threadId, runId: runId, entryPoint: graph.entryPoint)

            // Evaluate all metrics
            var scores: [EvalScore] = []
            for metric in metrics {
                do {
                    let score = try await metric.evaluate(scenario: scenario, finalState: finalState, trace: trace)
                    scores.append(score)
                } catch {
                    scores.append(.fail(metric: metric.name, reason: "Evaluation error: \(error.localizedDescription)"))
                }
            }

            let result = ScenarioEvalResult(
                scenarioId: scenario.id,
                scenarioName: scenario.name,
                finalState: finalState,
                trace: trace,
                scores: scores
            )
            scenarioResults.append(result)
        }

        return EvalReport(datasetName: dataset.name, scenarioResults: scenarioResults)
    }
}
