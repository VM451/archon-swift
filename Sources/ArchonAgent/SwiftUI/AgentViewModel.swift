import Foundation
import SwiftUI

/// Modern @Observable view model binding graph state machines directly into SwiftUI views.
@Observable
@MainActor
public final class AgentViewModel<State: AgentState> {
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
    @discardableResult
    public func start(with initialState: State? = nil) -> Task<Void, Never> {
        executionTask?.cancel()
        let runState = initialState ?? self.state
        let graph = self.graph
        let threadId = self.threadId
        isExecuting = true
        activeStreamingText = ""
        pendingInterrupt = nil

        let task = Task { @MainActor [weak self, graph, threadId, runState] in
            do {
                for try await event in graph.stream(initialState: runState, threadId: threadId) {
                    guard let self else { return }
                    self.apply(event)
                }
            } catch is CancellationError {
                // Cancellation is a normal lifecycle event, not a user-facing error.
            } catch {
                guard let self else { return }
                self.isExecuting = false
                self.executionLog.append("Error: \(error.localizedDescription)")
            }
        }
        executionTask = task
        return task
    }

    /// Resumes an interrupted graph after human review.
    @discardableResult
    public func resume(approved: Bool, updatedState: State? = nil) -> Task<Void, Never> {
        guard pendingInterrupt != nil else {
            return Task { @MainActor in }
        }

        executionTask?.cancel()
        let graph = self.graph
        let threadId = self.threadId
        let resumeState = updatedState ?? self.state
        pendingInterrupt = nil
        isExecuting = true
        activeStreamingText = ""

        let task = Task { @MainActor [weak self, graph, threadId, resumeState, approved] in
            do {
                let stream = try await graph.resumeStream(
                    threadId: threadId,
                    with: resumeState,
                    approval: approved
                )
                guard let self else { return }
                for try await event in stream {
                    self.apply(event)
                }
                self.executionLog.append("Graph resumed and finished successfully.")
            } catch is CancellationError {
                // Cancellation is a normal lifecycle event, not a user-facing error.
            } catch {
                guard let self else { return }
                self.isExecuting = false
                self.executionLog.append("Resume Error: \(error.localizedDescription)")
            }
        }
        executionTask = task
        return task
    }

    /// Applies one graph event to the observable UI state.
    private func apply(_ event: GraphEvent<State>) {
        switch event {
        case .started:
            executionLog.append("Graph execution started.")
        case .nodeStarted(let nodeId, _, let step):
            currentNodeId = nodeId
            executionLog.append("Step \(step): Running node '\(nodeId)'...")
        case .modelResponseChunk(_, let chunk, _):
            if let delta = chunk.deltaText {
                activeStreamingText.append(delta)
            }
        case .nodeCompleted(let nodeId, let updatedState, let duration, let step):
            state = updatedState
            executionLog.append("Step \(step): Completed node '\(nodeId)' in \(String(format: "%.3f", duration))s")
        case .interrupted(let interrupt, let interruptedState, let nodeId):
            state = interruptedState
            pendingInterrupt = interrupt
            isExecuting = false
            executionLog.append("⚠️ Interrupted at node '\(nodeId)': \(interrupt.message)")
        case .checkpointSaved(let id, let node):
            executionLog.append("Checkpoint saved for node '\(node)' (\(id.prefix(6)))")
        case .completed(let finalState, let steps):
            state = finalState
            isExecuting = false
            currentNodeId = EndNode.id
            if !activeStreamingText.isEmpty {
                messages.append(.assistant(activeStreamingText))
                activeStreamingText = ""
            }
            executionLog.append("Graph completed successfully in \(steps) steps.")
        case .edgeEvaluated:
            break
        }
    }

    /// Cancels active execution.
    public func cancel() {
        executionTask?.cancel()
        isExecuting = false
        executionLog.append("Execution cancelled by user.")
    }
}
