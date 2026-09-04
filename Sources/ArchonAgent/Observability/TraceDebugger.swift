import Foundation

/// Differentiator and state change inspector between adjacent execution steps.
public struct StepDiff: Sendable, Codable, Equatable {
    public let fromStep: Int
    public let toStep: Int
    public let fromNodeId: String
    public let toNodeId: String
    public let changedKeys: [String]
    public let stateDiffSummary: String

    public init(
        fromStep: Int,
        toStep: Int,
        fromNodeId: String,
        toNodeId: String,
        changedKeys: [String],
        stateDiffSummary: String
    ) {
        self.fromStep = fromStep
        self.toStep = toStep
        self.fromNodeId = fromNodeId
        self.toNodeId = toNodeId
        self.changedKeys = changedKeys
        self.stateDiffSummary = stateDiffSummary
    }
}

/// StepInspector compares state snapshots, inspects payload changes, and surfaces exact mutation diffs.
public struct StepInspector: Sendable {
    public init() {}

    /// Computes dictionary-level diff between two JSON state snapshots or string representations.
    public func diff(
        fromState: [String: String],
        toState: [String: String],
        fromStep: Int,
        toStep: Int,
        fromNode: String,
        toNode: String
    ) -> StepDiff {
        var changed: [String] = []
        var lines: [String] = []

        let allKeys = Set(fromState.keys).union(toState.keys).sorted()
        for key in allKeys {
            let valA = fromState[key]
            let valB = toState[key]
            if valA != valB {
                changed.append(key)
                if let a = valA, let b = valB {
                    lines.append("~ [\(key)]: \"\(a)\" -> \"\(b)\"")
                } else if let b = valB {
                    lines.append("+ [\(key)]: \"\(b)\"")
                } else if let a = valA {
                    lines.append("- [\(key)]: \"\(a)\"")
                }
            }
        }

        return StepDiff(
            fromStep: fromStep,
            toStep: toStep,
            fromNodeId: fromNode,
            toNodeId: toNode,
            changedKeys: changed,
            stateDiffSummary: lines.joined(separator: "\n")
        )
    }
}

/// Interactive Replay and Debugging Engine for stepping through recorded agent runs.
public final class ReplayEngine: Sendable {
    private let checkpointer: any StateCheckpointer
    private let inspector: StepInspector

    public init(checkpointer: any StateCheckpointer) {
        self.checkpointer = checkpointer
        self.inspector = StepInspector()
    }

    /// Fetches all checkpoint steps for a given thread in sequential order.
    public func loadHistory(threadId: String) async throws -> [CheckpointRecord] {
        let records = try await checkpointer.getHistory(threadId: threadId)
        return records.sorted { $0.stepIndex < $1.stepIndex }
    }

    /// Computes step-by-step diffs across all sequential transitions in the thread history.
    public func generateStepDiffs(threadId: String) async throws -> [StepDiff] {
        let history = try await loadHistory(threadId: threadId)
        guard history.count >= 2 else { return [] }

        var diffs: [StepDiff] = []
        for i in 0..<(history.count - 1) {
            let prev = history[i]
            let next = history[i + 1]

            let dictA = parseToFlatDictionary(data: prev.stateData)
            let dictB = parseToFlatDictionary(data: next.stateData)

            let diff = inspector.diff(
                fromState: dictA,
                toState: dictB,
                fromStep: prev.stepIndex,
                toStep: next.stepIndex,
                fromNode: prev.nodeId,
                toNode: next.nodeId
            )
            diffs.append(diff)
        }
        return diffs
    }

    private func parseToFlatDictionary(data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: String] = [:]
        if let dict = json as? [String: Any] {
            flatten(dict: dict, prefix: "", into: &result)
        }
        return result
    }

    private func flatten(dict: [String: Any], prefix: String, into: inout [String: String]) {
        for (k, v) in dict {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let nested = v as? [String: Any] {
                flatten(dict: nested, prefix: key, into: &into)
                for (nk, nv) in nested {
                    into[nk] = "\(nv)"
                }
            } else {
                into[k] = "\(v)"
                into[key] = "\(v)"
            }
        }
    }

    /// Reconstructs the exact state at a historical step.
    public func reconstructState<S: AgentState>(
        threadId: String,
        stepIndex: Int,
        as type: S.Type
    ) async throws -> S {
        let history = try await loadHistory(threadId: threadId)
        guard let record = history.first(where: { $0.stepIndex == stepIndex }) else {
            throw GraphError.graphHalted(reason: "No checkpoint found at step \(stepIndex) for thread '\(threadId)'.")
        }
        return try record.decodeState(as: S.self)
    }

    /// Forks execution from a specific step index to allow what-if scenario testing and debugging.
    public func fork(
        threadId: String,
        atStepIndex stepIndex: Int,
        newThreadId: String = UUID().uuidString
    ) async throws -> (newThreadId: String, checkpoint: CheckpointRecord) {
        let history = try await loadHistory(threadId: threadId)
        guard let target = history.first(where: { $0.stepIndex == stepIndex }) else {
            throw GraphError.graphHalted(reason: "Step \(stepIndex) not found in thread '\(threadId)'.")
        }

        let forked = try await checkpointer.fork(
            threadId: threadId,
            fromCheckpointId: target.checkpointId,
            newThreadId: newThreadId
        )
        return (newThreadId, forked)
    }
}
