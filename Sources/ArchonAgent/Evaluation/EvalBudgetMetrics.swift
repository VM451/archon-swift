import Foundation

/// Verifies tool calls occurred in a required relative order (ordered subsequence).
public struct ToolOrderEvaluator<S: AgentState>: EvalMetric {
    public let name: String = "ToolOrder"
    public let expectedOrder: [String]

    public init(expectedOrder: [String]) {
        self.expectedOrder = expectedOrder
    }

    public func evaluate(scenario: EvalScenario<S>, finalState: S, trace: RunTrace) async throws -> EvalScore {
        guard !expectedOrder.isEmpty else {
            return .pass(metric: name, reason: "No tool order specified.")
        }
        let invoked = trace.spans.filter { $0.kind == .tool }.map(\.name)
        var cursor = 0
        var matched = 0
        for expected in expectedOrder {
            if let index = invoked[cursor...].firstIndex(of: expected) {
                matched += 1
                cursor = index + 1
            } else {
                break
            }
        }
        if matched == expectedOrder.count {
            return .pass(metric: name, reason: "Tool order matched: [\(expectedOrder.joined(separator: ", "))]")
        }
        let score = Double(matched) / Double(expectedOrder.count)
        return .fail(
            metric: name, score: score,
            reason: "Tool order violated at '\(expectedOrder[matched])'. Invoked: [\(invoked.joined(separator: ", "))]"
        )
    }
}

/// Verifies total token usage stays within a local budget.
public struct TokenBudgetEvaluator<S: AgentState>: EvalMetric {
    public let name: String = "TokenBudget"
    public let maxTokens: Int

    public init(maxTokens: Int) {
        self.maxTokens = max(0, maxTokens)
    }

    public func evaluate(scenario: EvalScenario<S>, finalState: S, trace: RunTrace) async throws -> EvalScore {
        let total = trace.totalTokens.totalTokens
        if total <= maxTokens {
            return .pass(metric: name, reason: "Tokens \(total) <= budget \(maxTokens).")
        }
        return .fail(metric: name, score: 0.0, reason: "Tokens \(total) exceeded budget \(maxTokens).")
    }
}

/// Options controlling a deterministic local evaluation run.
public struct EvalRunOptions: Sendable {
    public let perScenarioTimeout: Duration?
    public let failFast: Bool
    public let seed: UInt64?

    public init(perScenarioTimeout: Duration? = nil, failFast: Bool = false, seed: UInt64? = nil) {
        self.perScenarioTimeout = perScenarioTimeout
        self.failFast = failFast
        self.seed = seed
    }
}

/// Typed evaluation-run failures.
public enum EvalRunError: Error, LocalizedError, Sendable, Equatable {
    case scenarioTimeout(scenarioId: String)

    public var errorDescription: String? {
        switch self {
        case .scenarioTimeout(let id):
            "Evaluation scenario timed out: \(id)"
        }
    }
}

public extension AgentEvalRunner {
    /// Evaluates a graph across a dataset with per-scenario timeouts, fail-fast
    /// short-circuiting, and seeded deterministic scenario ordering.
    func run(
        graph: Graph<State>,
        dataset: EvalDataset<State>,
        tracer: ExecutionTracer = ExecutionTracer(),
        options: EvalRunOptions
    ) async throws -> EvalReport<State> {
        let scenarios = Self.orderedScenarios(dataset.scenarios, seed: options.seed)
        var scenarioResults: [ScenarioEvalResult<State>] = []
        scenarioResults.reserveCapacity(scenarios.count)

        for scenario in scenarios {
            try Task.checkCancellation()
            let threadId = "eval-\(scenario.id)"
            let runId = UUID().uuidString

            await tracer.startRun(threadId: threadId, runId: runId, entryPoint: graph.entryPoint, metadata: scenario.metadata)
            let rootSpan = await tracer.startSpan(runId: runId, name: scenario.name, kind: .graph)

            var finalState = scenario.inputState
            var capturedError: String? = nil
            var timedOut = false

            do {
                if let timeout = options.perScenarioTimeout {
                    finalState = try await Self.withTimeout(timeout, scenarioId: scenario.id) {
                        try await graph.invoke(
                            initialState: scenario.inputState,
                            threadId: threadId,
                            metadata: scenario.metadata
                        )
                    }
                } else {
                    finalState = try await graph.invoke(
                        initialState: scenario.inputState,
                        threadId: threadId,
                        metadata: scenario.metadata
                    )
                }
            } catch let error as EvalRunError {
                capturedError = error.localizedDescription
                timedOut = true
            } catch {
                capturedError = error.localizedDescription
            }

            await tracer.endSpan(
                spanId: rootSpan.id,
                runId: runId,
                status: capturedError == nil ? .completed : .failed,
                errorMessage: capturedError
            )
            let trace = await tracer.endRun(runId: runId, status: capturedError == nil ? .completed : .failed)
                ?? RunTrace(threadId: threadId, runId: runId, entryPoint: graph.entryPoint)

            var scores: [EvalScore] = []
            if timedOut {
                scores.append(.fail(
                    metric: "ScenarioTimeout",
                    reason: capturedError ?? "Scenario timed out."
                ))
            }
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
            if options.failFast, !result.isPassing {
                break
            }
        }

        return EvalReport(datasetName: dataset.name, scenarioResults: scenarioResults)
    }

    /// Deterministic scenario ordering: identity order without a seed, seeded
    /// Fisher-Yates shuffle with one.
    static func orderedScenarios(_ scenarios: [EvalScenario<State>], seed: UInt64?) -> [EvalScenario<State>] {
        guard let seed else { return scenarios }
        var rng = SeededRNG(seed: seed)
        var ordered = scenarios
        if ordered.count > 1 {
            for index in stride(from: ordered.count - 1, through: 1, by: -1) {
                let swap = Int(rng.next() % UInt64(index + 1))
                ordered.swapAt(index, swap)
            }
        }
        return ordered
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        scenarioId: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome: EvalTimeoutOutcome<T> = await withTaskGroup(of: EvalTimeoutOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .success(try await operation())
                } catch {
                    return .failure(EvalBoxedError(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timeout
                } catch {
                    return .failure(EvalBoxedError(error))
                }
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            for await _ in group {}
            return first
        }
        switch outcome {
        case .success(let value):
            return value
        case .timeout:
            throw EvalRunError.scenarioTimeout(scenarioId: scenarioId)
        case .failure(let boxed):
            throw boxed.error
        }
    }
}

/// Sendable outcome for the per-scenario timeout race.
private enum EvalTimeoutOutcome<T: Sendable>: Sendable {
    case success(T)
    case timeout
    case failure(EvalBoxedError)
}

/// Unchecked box so arbitrary operation errors can cross task-group boundaries.
private struct EvalBoxedError: @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
}

/// Minimal deterministic RNG (splitmix64) for seeded scenario ordering.
struct SeededRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        var z = state &+ 0x9E37_79B9_7F4A_7C15
        state = z
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct ScenarioEvalResultDTO<S: AgentState>: Codable {
    let scenarioId: String
    let scenarioName: String
    let finalState: S
    let trace: RunTrace
    let scores: [EvalScore]
    let isPassing: Bool
    let duration: TimeInterval
    let costUSD: Double
}

private struct EvalReportDTO<S: AgentState>: Codable {
    let datasetName: String
    let totalScenarios: Int
    let passedScenarios: Int
    let passRatePercentage: Double
    let averageScore: Double
    let averageDuration: TimeInterval
    let totalTokens: TokenUsage
    let totalCostUSD: Double
    let scenarioResults: [ScenarioEvalResultDTO<S>]
    let timestamp: Date
}

public extension EvalReport {
    /// Serializes the report to JSON with stable key order and scenario order.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let ordered = scenarioResults.sorted { $0.scenarioId < $1.scenarioId }
        let dto = EvalReportDTO(
            datasetName: datasetName,
            totalScenarios: totalScenarios,
            passedScenarios: passedScenarios,
            passRatePercentage: passRatePercentage,
            averageScore: averageScore,
            averageDuration: averageDuration,
            totalTokens: totalTokens,
            totalCostUSD: totalCostUSD,
            scenarioResults: ordered.map {
                ScenarioEvalResultDTO(
                    scenarioId: $0.scenarioId, scenarioName: $0.scenarioName,
                    finalState: $0.finalState, trace: $0.trace, scores: $0.scores,
                    isPassing: $0.isPassing, duration: $0.duration, costUSD: $0.costUSD
                )
            },
            timestamp: timestamp
        )
        return try encoder.encode(dto)
    }
}
