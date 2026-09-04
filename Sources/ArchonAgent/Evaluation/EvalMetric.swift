import Foundation

/// Score and assertion outcome from an evaluation metric.
public struct EvalScore: Sendable, Codable, Equatable {
    public let metricName: String
    public let score: Double // Range 0.0 ... 1.0
    public let isPassing: Bool
    public let reason: String

    public init(metricName: String, score: Double, isPassing: Bool, reason: String = "") {
        self.metricName = metricName
        self.score = min(max(score, 0.0), 1.0)
        self.isPassing = isPassing
        self.reason = reason
    }

    public static func pass(metric: String, score: Double = 1.0, reason: String = "Passed") -> EvalScore {
        EvalScore(metricName: metric, score: score, isPassing: true, reason: reason)
    }

    public static func fail(metric: String, score: Double = 0.0, reason: String) -> EvalScore {
        EvalScore(metricName: metric, score: score, isPassing: false, reason: reason)
    }
}

/// Protocol defining an automated evaluation metric or judge.
public protocol EvalMetric<State>: Sendable {
    associatedtype State: AgentState
    var name: String { get }
    func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore
}

/// Evaluator that verifies exact substring presence in the final state's text fields or serialized output.
public struct ContainsEvaluator<State: AgentState>: EvalMetric {
    public let name: String = "ContainsSubstring"

    public init() {}

    public func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore {
        guard !scenario.expectedOutputSubstrings.isEmpty else {
            return .pass(metric: name, reason: "No substrings specified.")
        }

        let serializedState: String
        if let data = try? JSONEncoder().encode(finalState) {
            serializedState = String(decoding: data, as: UTF8.self)
        } else {
            serializedState = String(describing: finalState)
        }

        var missing: [String] = []
        for expected in scenario.expectedOutputSubstrings {
            if !serializedState.localizedCaseInsensitiveContains(expected) {
                missing.append(expected)
            }
        }

        if missing.isEmpty {
            return .pass(metric: name, reason: "All \(scenario.expectedOutputSubstrings.count) expected substrings matched.")
        } else {
            let score = 1.0 - (Double(missing.count) / Double(scenario.expectedOutputSubstrings.count))
            return .fail(metric: name, score: score, reason: "Missing substrings: [\(missing.joined(separator: ", "))]")
        }
    }
}

/// Evaluator that asserts tool invocation correctness and prohibits unauthorized tool calls.
public struct ToolCallSequenceEvaluator<State: AgentState>: EvalMetric {
    public let name: String = "ToolCallSequence"

    public init() {}

    public func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore {
        let invokedToolNames = trace.spans.filter { $0.kind == .tool }.map(\.name)

        // Check prohibited tools
        for prohibited in scenario.prohibitedToolCalls {
            if invokedToolNames.contains(prohibited) {
                return .fail(metric: name, score: 0.0, reason: "Prohibited tool '\(prohibited)' was invoked.")
            }
        }

        // Check expected tools
        if scenario.expectedToolCalls.isEmpty {
            return .pass(metric: name, reason: "No expected tool calls specified.")
        }

        var missing: [String] = []
        for expected in scenario.expectedToolCalls {
            if !invokedToolNames.contains(expected) {
                missing.append(expected)
            }
        }

        if missing.isEmpty {
            return .pass(metric: name, reason: "All expected tools invoked: [\(scenario.expectedToolCalls.joined(separator: ", "))]")
        } else {
            let score = 1.0 - (Double(missing.count) / Double(scenario.expectedToolCalls.count))
            return .fail(metric: name, score: score, reason: "Missing expected tool calls: [\(missing.joined(separator: ", "))]")
        }
    }
}

/// Evaluator that verifies latency stays below the threshold.
public struct LatencyEvaluator<State: AgentState>: EvalMetric {
    public let name: String = "LatencySLA"

    public init() {}

    public func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore {
        guard let maxLatency = scenario.maxLatencySeconds else {
            return .pass(metric: name, reason: "No latency threshold specified.")
        }

        let actual = trace.totalDuration ?? 0.0
        if actual <= maxLatency {
            return .pass(metric: name, reason: "Duration \(String(format: "%.3f", actual))s <= SLA \(maxLatency)s.")
        } else {
            return .fail(metric: name, score: 0.0, reason: "Duration \(String(format: "%.3f", actual))s exceeded SLA limit \(maxLatency)s.")
        }
    }
}

/// Evaluator that verifies cost in USD stays within budget.
public struct CostBudgetEvaluator<State: AgentState>: EvalMetric {
    public let name: String = "CostBudget"

    public init() {}

    public func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore {
        guard let budget = scenario.maxCostBudgetUSD else {
            return .pass(metric: name, reason: "No cost budget specified.")
        }

        let cost = trace.totalCostUSD
        if cost <= budget {
            return .pass(metric: name, reason: "Cost $\(String(format: "%.5f", cost)) <= Budget $\(String(format: "%.5f", budget)).")
        } else {
            return .fail(metric: name, score: 0.0, reason: "Cost $\(String(format: "%.5f", cost)) exceeded Budget $\(String(format: "%.5f", budget)).")
        }
    }
}

/// Evaluator that uses an LLM judge to grade answers against qualitative rubrics.
public struct LLMAsJudgeEvaluator<State: AgentState>: EvalMetric {
    public let name: String = "LLMAsJudge"
    public let judgeProvider: any LLMProvider

    public init(judgeProvider: any LLMProvider) {
        self.judgeProvider = judgeProvider
    }

    public func evaluate(scenario: EvalScenario<State>, finalState: State, trace: RunTrace) async throws -> EvalScore {
        guard let rubric = scenario.rubricCriteria, !rubric.isEmpty else {
            return .pass(metric: name, reason: "No rubric criteria provided.")
        }

        let stateString: String
        if let data = try? JSONEncoder().encode(finalState) {
            stateString = String(decoding: data, as: UTF8.self)
        } else {
            stateString = String(describing: finalState)
        }

        let prompt: [ChatMessage] = [
            .system("You are an expert AI Agent Evaluator. You grade agent performance strictly according to the provided rubric. Output your evaluation in the format: 'SCORE: <0.0-1.0>' followed by 'REASON: <reasoning>'."),
            .user("""
            Scenario: \(scenario.name)
            Rubric: \(rubric)
            Agent Final State: \(stateString)
            Execution Spans: \(trace.spans.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: " -> "))
            """)
        ]

        let response = try await judgeProvider.generate(prompt: prompt)
        let text = response.text

        var score = 1.0
        var isPass = true
        if let scoreRange = text.range(of: "SCORE:") {
            let after = text[scoreRange.upperBound...]
            let scanner = Scanner(string: String(after))
            if let parsed = scanner.scanDouble() {
                score = parsed
                isPass = parsed >= 0.7
            }
        }

        return EvalScore(metricName: name, score: score, isPassing: isPass, reason: text)
    }
}
