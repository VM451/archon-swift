import Foundation
import SwiftUI

/// Modern @Observable view model binding graph state machines directly into SwiftUI views.
@Observable
public final class AgentViewModel<State: AgentState>: @unchecked Sendable {
    public var state: State
    public var messages: [ChatMessage] = []
    public var currentNodeId: String = ""
    public var isExecuting: Bool = false
    public var pendingInterrupt: GraphInterrupt? = nil
    public var checkpoints: [CheckpointRecord] = []
    public var executionLog: [String] = []
    public var activeStreamingText: String = ""

    private let graph: Graph<State>
    public let threadId: String
    private var executionTask: Task<Void, Never>?

    public init(graph: Graph<State>, initialState: State = State(), threadId: String = UUID().uuidString) {
        self.graph = graph
        self.state = initialState
        self.threadId = threadId
    }

    /// Starts graph execution stream and binds events directly to UI observables.
    public func start(with initialState: State? = nil) {
        let runState = initialState ?? self.state
        isExecuting = true
        activeStreamingText = ""
        pendingInterrupt = nil

        executionTask = Task { @MainActor in
            do {
                for try await event in self.graph.stream(initialState: runState, threadId: self.threadId) {
                    switch event {
                    case .started:
                        self.executionLog.append("Graph execution started.")
                    case .nodeStarted(let nodeId, _, let step):
                        self.currentNodeId = nodeId
                        self.executionLog.append("Step \(step): Running node '\(nodeId)'...")
                    case .nodeCompleted(let nodeId, let updatedState, let duration, let step):
                        self.state = updatedState
                        self.executionLog.append("Step \(step): Completed node '\(nodeId)' in \(String(format: "%.3f", duration))s")
                    case .interrupted(let interrupt, let interruptedState, let nodeId):
                        self.state = interruptedState
                        self.pendingInterrupt = interrupt
                        self.isExecuting = false
                        self.executionLog.append("⚠️ Interrupted at node '\(nodeId)': \(interrupt.message)")
                    case .checkpointSaved(let id, let node):
                        self.executionLog.append("Checkpoint saved for node '\(node)' (\(id.prefix(6)))")
                    case .completed(let finalState, let steps):
                        self.state = finalState
                        self.isExecuting = false
                        self.currentNodeId = EndNode.id
                        self.executionLog.append("Graph completed successfully in \(steps) steps.")
                    default:
                        break
                    }
                }
            } catch {
                self.isExecuting = false
                self.executionLog.append("Error: \(error.localizedDescription)")
            }
        }
    }

    /// Resumes an interrupted graph after human review.
    public func resume(approved: Bool, updatedState: State? = nil) {
        guard pendingInterrupt != nil else { return }
        pendingInterrupt = nil
        isExecuting = true

        executionTask = Task { @MainActor in
            do {
                let resumed = try await self.graph.resume(
                    threadId: self.threadId,
                    with: updatedState ?? self.state,
                    approval: approved
                )
                self.state = resumed
                self.isExecuting = false
                self.executionLog.append("Graph resumed and finished successfully.")
            } catch {
                self.isExecuting = false
                self.executionLog.append("Resume Error: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels active execution.
    public func cancel() {
        executionTask?.cancel()
        isExecuting = false
        executionLog.append("Execution cancelled by user.")
    }
}
