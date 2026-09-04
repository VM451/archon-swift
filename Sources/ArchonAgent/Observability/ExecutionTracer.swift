import Foundation

/// Defines the category or execution phase of an observability trace span.
public enum SpanKind: String, Codable, Sendable, Equatable {
    case graph
    case node
    case tool
    case llm
    case subgraph
    case checkpointer
    case interrupt
}

/// Execution status of a trace span.
public enum SpanStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case completed
    case failed
    case interrupted
}

/// Represents an individual timed trace span in an agent execution lifecycle.
public struct TraceSpan: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let parentSpanId: String?
    public let name: String
    public let kind: SpanKind
    public var status: SpanStatus
    public let startTime: Date
    public var endTime: Date?
    public var duration: TimeInterval?
    public var attributes: [String: String]
    public var inputStateSnapshot: String?
    public var outputStateSnapshot: String?
    public var tokenUsage: TokenUsage?
    public var estimatedCostUSD: Double?
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        parentSpanId: String? = nil,
        name: String,
        kind: SpanKind,
        status: SpanStatus = .running,
        startTime: Date = Date(),
        endTime: Date? = nil,
        duration: TimeInterval? = nil,
        attributes: [String: String] = [:],
        inputStateSnapshot: String? = nil,
        outputStateSnapshot: String? = nil,
        tokenUsage: TokenUsage? = nil,
        estimatedCostUSD: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.attributes = attributes
        self.inputStateSnapshot = inputStateSnapshot
        self.outputStateSnapshot = outputStateSnapshot
        self.tokenUsage = tokenUsage
        self.estimatedCostUSD = estimatedCostUSD
        self.errorMessage = errorMessage
    }

    /// Completes the span with end time, status, duration, and optional tokens/cost.
    public mutating func complete(
        status: SpanStatus = .completed,
        output: String? = nil,
        tokens: TokenUsage? = nil,
        costUSD: Double? = nil,
        error: String? = nil
    ) {
        let now = Date()
        self.endTime = now
        self.duration = now.timeIntervalSince(self.startTime)
        self.status = status
        if let output { self.outputStateSnapshot = output }
        if let tokens { self.tokenUsage = tokens }
        if let costUSD { self.estimatedCostUSD = costUSD }
        if let error { self.errorMessage = error }
    }
}

/// Represents the complete run trace of an agent graph execution.
public struct RunTrace: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let threadId: String
    public let runId: String
    public let entryPoint: String
    public let startTime: Date
    public var endTime: Date?
    public var totalDuration: TimeInterval?
    public var status: SpanStatus
    public var spans: [TraceSpan]
    public var totalTokens: TokenUsage
    public var totalCostUSD: Double
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        threadId: String,
        runId: String,
        entryPoint: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        totalDuration: TimeInterval? = nil,
        status: SpanStatus = .running,
        spans: [TraceSpan] = [],
        totalTokens: TokenUsage = TokenUsage(),
        totalCostUSD: Double = 0.0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.threadId = threadId
        self.runId = runId
        self.entryPoint = entryPoint
        self.startTime = startTime
        self.endTime = endTime
        self.totalDuration = totalDuration
        self.status = status
        self.spans = spans
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.metadata = metadata
    }

    /// Completes the run trace.
    public mutating func finalize(status: SpanStatus = .completed) {
        let now = Date()
        self.endTime = now
        self.totalDuration = now.timeIntervalSince(self.startTime)
        self.status = status

        // Aggregate tokens and costs from spans
        var prompt = 0
        var completion = 0
        var total = 0
        var cost: Double = 0.0

        for span in spans {
            if let usage = span.tokenUsage {
                prompt += usage.promptTokens
                completion += usage.completionTokens
                total += usage.totalTokens
            }
            if let spanCost = span.estimatedCostUSD {
                cost += spanCost
            }
        }

        self.totalTokens = TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
        self.totalCostUSD = cost
    }

    /// Renders an ASCII DAG execution tree.
    public func renderDAG() -> String {
        var lines: [String] = []
        lines.append("Execution Trace: [\(threadId)] (Run: \(runId))")
        lines.append("Status: \(status.rawValue.uppercased()) | Duration: \(String(format: "%.3f", totalDuration ?? 0))s | Tokens: \(totalTokens.totalTokens) | Cost: $\(String(format: "%.5f", totalCostUSD))")
        lines.append("--------------------------------------------------------------------------------")

        // Root spans
        let roots = spans.filter { $0.parentSpanId == nil }
        for root in roots {
            renderSpanTree(span: root, indent: "", isLast: true, lines: &lines)
        }

        return lines.joined(separator: "\n")
    }

    private func renderSpanTree(span: TraceSpan, indent: String, isLast: Bool, lines: inout [String]) {
        let marker = isLast ? "└── " : "├── "
        let durationStr = span.duration.map { String(format: "%.3fs", $0) } ?? "..."
        let tokenStr = span.tokenUsage.map { " | \($0.totalTokens) tokens" } ?? ""
        let costStr = span.estimatedCostUSD.map { " | $\(String(format: "%.5f", $0))" } ?? ""
        let errStr = span.errorMessage.map { " [ERROR: \($0)]" } ?? ""

        lines.append("\(indent)\(marker)[\(span.kind.rawValue)] \(span.name) (\(span.status.rawValue), \(durationStr)\(tokenStr)\(costStr))\(errStr)")

        let childIndent = indent + (isLast ? "    " : "│   ")
        let children = spans.filter { $0.parentSpanId == span.id }
        for (index, child) in children.enumerated() {
            renderSpanTree(span: child, indent: childIndent, isLast: index == children.count - 1, lines: &lines)
        }
    }

    /// Exports Mermaid flowchart representation of the execution run.
    public func renderMermaid() -> String {
        var lines: [String] = ["flowchart TD"]
        for span in spans {
            let label = "\(span.name)<br/>(\(span.kind.rawValue): \(span.duration.map { String(format: "%.2fs", $0) } ?? "..."))"
            lines.append("    \(span.id)[\"\(label)\"]")
            if let parent = span.parentSpanId {
                lines.append("    \(parent) --> \(span.id)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Serializes the run trace to formatted JSON string.
    public func exportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Thread-safe Execution Tracer actor that collects spans and produces structured run traces.
public actor ExecutionTracer {
    private var activeTraces: [String: RunTrace] = [:]
    private var completedTraces: [String: RunTrace] = [:]
    private var activeSpans: [String: TraceSpan] = [:]

    public init() {}

    /// Starts a new run trace for an agent graph execution.
    @discardableResult
    public func startRun(
        threadId: String,
        runId: String,
        entryPoint: String,
        metadata: [String: String] = [:]
    ) -> RunTrace {
        let trace = RunTrace(
            threadId: threadId,
            runId: runId,
            entryPoint: entryPoint,
            metadata: metadata
        )
        activeTraces[runId] = trace
        return trace
    }

    /// Starts a new span under a specific run.
    @discardableResult
    public func startSpan(
        runId: String,
        name: String,
        kind: SpanKind,
        parentSpanId: String? = nil,
        inputSnapshot: String? = nil,
        attributes: [String: String] = [:]
    ) -> TraceSpan {
        let span = TraceSpan(
            parentSpanId: parentSpanId,
            name: name,
            kind: kind,
            status: .running,
            attributes: attributes,
            inputStateSnapshot: inputSnapshot
        )
        activeSpans[span.id] = span
        return span
    }

    /// Ends an active span with status, outputs, token usage, and cost.
    @discardableResult
    public func endSpan(
        spanId: String,
        runId: String,
        status: SpanStatus = .completed,
        outputSnapshot: String? = nil,
        tokens: TokenUsage? = nil,
        costUSD: Double? = nil,
        errorMessage: String? = nil
    ) -> TraceSpan? {
        guard var span = activeSpans.removeValue(forKey: spanId) else { return nil }
        span.complete(status: status, output: outputSnapshot, tokens: tokens, costUSD: costUSD, error: errorMessage)

        if var trace = activeTraces[runId] {
            trace.spans.append(span)
            activeTraces[runId] = trace
        }
        return span
    }

    /// Finalizes a run trace.
    @discardableResult
    public func endRun(runId: String, status: SpanStatus = .completed) -> RunTrace? {
        guard var trace = activeTraces.removeValue(forKey: runId) else { return nil }
        trace.finalize(status: status)
        completedTraces[runId] = trace
        return trace
    }

    /// Fetches a completed or active run trace by ID.
    public func getTrace(runId: String) -> RunTrace? {
        completedTraces[runId] ?? activeTraces[runId]
    }

    /// Fetches all completed run traces.
    public func allCompletedTraces() -> [RunTrace] {
        Array(completedTraces.values)
    }

    /// Clears historical traces.
    public func reset() {
        activeTraces.removeAll()
        completedTraces.removeAll()
        activeSpans.removeAll()
    }
}
