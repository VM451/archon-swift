import Foundation

/// Head-to-head comparison results between two Agent Configurations (Variant A vs Variant B).
public struct ABExperimentComparison<State: AgentState>: Sendable {
    public let experimentName: String
    public let variantAName: String
    public let variantBName: String
    public let reportA: EvalReport<State>
    public let reportB: EvalReport<State>
    public let winRateA: Double
    public let winRateB: Double
    public let latencyDeltaPercent: Double
    public let costDeltaPercent: Double
    public let winningVariant: String

    public init(
        experimentName: String,
        variantAName: String,
        variantBName: String,
        reportA: EvalReport<State>,
        reportB: EvalReport<State>
    ) {
        self.experimentName = experimentName
        self.variantAName = variantAName
        self.variantBName = variantBName
        self.reportA = reportA
        self.reportB = reportB

        var winsA = 0
        var winsB = 0
        let pairCount = min(reportA.scenarioResults.count, reportB.scenarioResults.count)

        for i in 0..<pairCount {
            let resA = reportA.scenarioResults[i]
            let resB = reportB.scenarioResults[i]

            let avgA = resA.scores.map(\.score).reduce(0.0, +) / max(1.0, Double(resA.scores.count))
            let avgB = resB.scores.map(\.score).reduce(0.0, +) / max(1.0, Double(resB.scores.count))

            if avgA > avgB {
                winsA += 1
            } else if avgB > avgA {
                winsB += 1
            }
        }

        self.winRateA = pairCount > 0 ? (Double(winsA) / Double(pairCount)) * 100.0 : 0.0
        self.winRateB = pairCount > 0 ? (Double(winsB) / Double(pairCount)) * 100.0 : 0.0

        let latA = max(0.0001, reportA.averageDuration)
        let latB = reportB.averageDuration
        self.latencyDeltaPercent = ((latB - latA) / latA) * 100.0

        let costA = max(0.000001, reportA.totalCostUSD)
        let costB = reportB.totalCostUSD
        self.costDeltaPercent = ((costB - costA) / costA) * 100.0

        if reportA.averageScore > reportB.averageScore {
            self.winningVariant = variantAName
        } else if reportB.averageScore > reportA.averageScore {
            self.winningVariant = variantBName
        } else {
            self.winningVariant = reportA.averageDuration <= reportB.averageDuration ? variantAName : variantBName
        }
    }

    /// Formats a clean head-to-head comparison table.
    public func formattedReport() -> String {
        var lines: [String] = []
        lines.append("================================================================================")
        lines.append("A/B EXPERIMENT REPORT: \(experimentName)")
        lines.append("Winner: 🏆 \(winningVariant)")
        lines.append("--------------------------------------------------------------------------------")
        lines.append("Metric                    | \(variantAName)            | \(variantBName)")
        lines.append("--------------------------------------------------------------------------------")
        lines.append("Pass Rate                 | \(String(format: "%.1f%%", reportA.passRatePercentage))                  | \(String(format: "%.1f%%", reportB.passRatePercentage))")
        lines.append("Avg Quality Score         | \(String(format: "%.2f", reportA.averageScore))                  | \(String(format: "%.2f", reportB.averageScore))")
        lines.append("Avg Latency               | \(String(format: "%.3fs", reportA.averageDuration))                 | \(String(format: "%.3fs", reportB.averageDuration))")
        lines.append("Total Cost USD            | $\(String(format: "%.5f", reportA.totalCostUSD))               | $\(String(format: "%.5f", reportB.totalCostUSD))")
        lines.append("Head-to-Head Win Rate     | \(String(format: "%.1f%%", winRateA))                  | \(String(format: "%.1f%%", winRateB))")
        lines.append("================================================================================")
        return lines.joined(separator: "\n")
    }
}

/// A/B Testing Harness for executing side-by-side agent evaluations.
public struct AgentABExperiment<State: AgentState>: Sendable {
    public let name: String
    public let variantAName: String
    public let variantBName: String
    public let runner: AgentEvalRunner<State>

    public init(
        name: String,
        variantAName: String = "Variant A",
        variantBName: String = "Variant B",
        runner: AgentEvalRunner<State> = AgentEvalRunner()
    ) {
        self.name = name
        self.variantAName = variantAName
        self.variantBName = variantBName
        self.runner = runner
    }

    /// Evaluates Variant Graph A against Variant Graph B over the same dataset.
    public func compare(
        graphA: Graph<State>,
        graphB: Graph<State>,
        dataset: EvalDataset<State>
    ) async throws -> ABExperimentComparison<State> {
        let tracerA = ExecutionTracer()
        let tracerB = ExecutionTracer()

        let reportA = try await runner.run(graph: graphA, dataset: dataset, tracer: tracerA)
        let reportB = try await runner.run(graph: graphB, dataset: dataset, tracer: tracerB)

        return ABExperimentComparison(
            experimentName: name,
            variantAName: variantAName,
            variantBName: variantBName,
            reportA: reportA,
            reportB: reportB
        )
    }
}
