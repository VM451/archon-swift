import Foundation

/// Events emitted during execution of an agent graph.
public enum GraphEvent<State: AgentState>: Sendable {
    case started(threadId: String, runId: String)
    case nodeStarted(nodeId: String, state: State, step: Int)
    case nodeCompleted(nodeId: String, state: State, duration: TimeInterval, step: Int)
    case edgeEvaluated(from: String, to: String)
    case interrupted(interrupt: GraphInterrupt, state: State, nodeId: String)
    case checkpointSaved(checkpointId: String, nodeId: String)
    case completed(finalState: State, totalSteps: Int)
}

/// Represents the compiled, executable agent state graph.
public final class Graph<State: AgentState>: Sendable {
    public let entryPoint: String
    private let nodes: [String: any AgentNode<State>]
    private let edges: [String: AgentEdge<State>]
    public let maxRecursionDepth: Int
    public let checkpointer: (any StateCheckpointer)?
    private let dispatcher: NodeDispatcher<State>

    public init(
        entryPoint: String,
        nodes: [String: any AgentNode<State>],
        edges: [String: AgentEdge<State>],
        maxRecursionDepth: Int = 50,
        checkpointer: (any StateCheckpointer)? = nil,
        dispatcher: NodeDispatcher<State> = NodeDispatcher()
    ) {
        self.entryPoint = entryPoint
        self.nodes = nodes
        self.edges = edges
        self.maxRecursionDepth = maxRecursionDepth
        self.checkpointer = checkpointer
        self.dispatcher = dispatcher
    }

    /// Invokes the graph synchronously from the entry point until EndNode is reached.
    public func invoke(
        initialState: State = State(),
        threadId: String = UUID().uuidString,
        metadata: [String: String] = [:]
    ) async throws -> State {
        var finalState = initialState
        for try await event in stream(initialState: initialState, threadId: threadId, metadata: metadata) {
            switch event {
            case .completed(let state, _):
                finalState = state
            case .interrupted(let interrupt, _, _):
                throw GraphError.interrupted(message: interrupt.message, threadId: threadId)
            default:
                break
            }
        }
        return finalState
    }

    /// Executes the graph while streaming real-time lifecycle events.
    public func stream(
        initialState: State = State(),
        threadId: String = UUID().uuidString,
        metadata: [String: String] = [:]
    ) -> AsyncThrowingStream<GraphEvent<State>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var currentState = initialState
                    var currentNodeId = self.entryPoint
                    var context = ExecutionContext(
                        threadId: threadId,
                        runId: UUID().uuidString,
                        currentNodeId: currentNodeId,
                        stepIndex: 0,
                        metadata: metadata
                    )

                    continuation.yield(.started(threadId: threadId, runId: context.runId))

                    // Initial checkpoint save
                    if let checkpointer = self.checkpointer {
                        let record = CheckpointRecord(
                            threadId: threadId,
                            runId: context.runId,
                            nodeId: StartNode.id,
                            stepIndex: 0,
                            state: currentState,
                            metadata: metadata
                        )
                        try await checkpointer.save(record: record)
                        continuation.yield(.checkpointSaved(checkpointId: record.checkpointId, nodeId: StartNode.id))
                    }

                    var stepCount = 0

                    while currentNodeId != EndNode.id {
                        try Task.checkCancellation()

                        if stepCount >= self.maxRecursionDepth {
                            throw GraphError.recursionLimitExceeded(limit: self.maxRecursionDepth, currentNodeId: currentNodeId)
                        }

                        guard let node = self.nodes[currentNodeId] else {
                            throw GraphError.nodeNotFound(nodeId: currentNodeId)
                        }

                        context = context.advancing(to: currentNodeId)
                        continuation.yield(.nodeStarted(nodeId: currentNodeId, state: currentState, step: stepCount))

                        // Dispatch node execution
                        let (nextState, duration): (State, TimeInterval)
                        do {
                            (nextState, duration) = try await self.dispatcher.dispatch(
                                node: node,
                                state: currentState,
                                context: context
                            )
                        } catch let interrupt as GraphInterrupt {
                            // Save interrupted state
                            if let checkpointer = self.checkpointer {
                                let record = CheckpointRecord(
                                    threadId: threadId,
                                    runId: context.runId,
                                    nodeId: currentNodeId,
                                    stepIndex: stepCount,
                                    state: currentState,
                                    isInterrupted: true,
                                    interruptMessage: interrupt.message,
                                    metadata: metadata
                                )
                                try? await checkpointer.save(record: record)
                            }
                            continuation.yield(.interrupted(interrupt: interrupt, state: currentState, nodeId: currentNodeId))
                            continuation.finish()
                            return
                        }

                        currentState = nextState
                        stepCount += 1

                        continuation.yield(.nodeCompleted(
                            nodeId: currentNodeId,
                            state: currentState,
                            duration: duration,
                            step: stepCount
                        ))

                        // Persist checkpoint after node completion
                        if let checkpointer = self.checkpointer {
                            let record = CheckpointRecord(
                                threadId: threadId,
                                runId: context.runId,
                                nodeId: currentNodeId,
                                stepIndex: stepCount,
                                state: currentState,
                                metadata: metadata
                            )
                            try await checkpointer.save(record: record)
                            continuation.yield(.checkpointSaved(checkpointId: record.checkpointId, nodeId: currentNodeId))
                        }

                        // Determine next node via edges
                        if let edge = self.edges[currentNodeId] {
                            let nextTarget = try await edge.resolveNext(state: currentState, context: context)
                            continuation.yield(.edgeEvaluated(from: currentNodeId, to: nextTarget))
                            currentNodeId = nextTarget
                        } else {
                            // If no explicit edge, terminate at EndNode
                            currentNodeId = EndNode.id
                        }
                    }

                    continuation.yield(.completed(finalState: currentState, totalSteps: stepCount))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Resumes an interrupted or historical thread from its latest saved checkpoint.
    public func resume(
        threadId: String,
        with inputs: State? = nil,
        approval: Bool = true
    ) async throws -> State {
        guard let checkpointer = self.checkpointer else {
            throw GraphError.graphHalted(reason: "Cannot resume graph without an active checkpointer.")
        }

        guard let latest = try await checkpointer.getLatest(threadId: threadId, as: State.self) else {
            throw GraphError.graphHalted(reason: "No checkpoint found for thread '\(threadId)'.")
        }

        guard approval else {
            throw GraphError.graphHalted(reason: "Approval was rejected; the interrupted graph was not resumed.")
        }

        let resumeState = inputs ?? latest.state
        let lastNode = latest.nodeId

        // If the latest checkpoint was an interrupted node and approved, resolve next node
        var nextNodeId = EndNode.id
        if let edge = self.edges[lastNode] {
            let context = ExecutionContext(
                threadId: threadId,
                runId: latest.runId,
                currentNodeId: lastNode,
                stepIndex: latest.stepIndex
            )
            nextNodeId = try await edge.resolveNext(state: resumeState, context: context)
        }

        if nextNodeId == EndNode.id {
            return resumeState
        }

        // Create a sub-execution starting from nextNodeId
        let builder = GraphBuilder<State>()
        for (_, node) in self.nodes {
            builder.addNode(node)
        }
        for (_, edge) in self.edges {
            builder.addEdge(edge)
        }
        builder.setEntryPoint(nextNodeId)

        let subGraph = try builder.compile(
            checkpointer: self.checkpointer,
            maxRecursionDepth: self.maxRecursionDepth
        )

        return try await subGraph.invoke(
            initialState: resumeState,
            threadId: threadId,
            metadata: latest.metadata
        )
    }
}
