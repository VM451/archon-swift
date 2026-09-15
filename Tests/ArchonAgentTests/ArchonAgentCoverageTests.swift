import Testing
import Foundation
@testable import ArchonAgent

private struct CoverageState: AgentState {
    var count: Int = 0
    var message: String = ""
    var items: [String] = []
    var scores: [String: Int] = [:]
    var total: Int = 0
}

private func singleStepGraph(
    maxRecursionDepth: Int = 50,
    checkpointer: (any StateCheckpointer)? = nil
) throws -> Graph<CoverageState> {
    let builder = GraphBuilder<CoverageState>()
    builder.addNode("step") { state in
        var next = state
        next.count += 1
        return next
    }
    builder.setEntryPoint("step")
    builder.addEdge(from: "step", to: EndNode.id)
    return try builder.compile(checkpointer: checkpointer, maxRecursionDepth: maxRecursionDepth)
}

@Suite("ArchonAgent Coverage Tests")
struct ArchonAgentCoverageTests {

    // MARK: - Common behavior

    @Test("Direct edge invoke runs nodes in order")
    func directEdgeInvoke() async throws {
        let graph = try singleStepGraph()
        let result = try await graph.invoke(initialState: CoverageState())
        #expect(result.count == 1)
    }

    @Test("Mutation action node updates state in place")
    func mutationActionNode() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("mut", mutationAction: { (state: inout CoverageState) async throws in
            state.message = "hello"
        })
        builder.setEntryPoint("mut")
        builder.addEdge(from: "mut", to: EndNode.id)
        let result = try await builder.compile().invoke(initialState: CoverageState())
        #expect(result.message == "hello")
    }

    @Test("Full action node can return unchanged")
    func unchangedNodeResult() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("noop", description: "noop") { (state: CoverageState, _: ExecutionContext) async throws in
            .unchanged
        }
        builder.setEntryPoint("noop")
        builder.addEdge(from: "noop", to: EndNode.id)
        let result = try await builder.compile().invoke(initialState: CoverageState(count: 7))
        #expect(result.count == 7)
    }

    @Test("Dictionary node result applies registered reducer")
    func dictionaryResultWithReducer() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("emit", description: "emit") { (_: CoverageState, _: ExecutionContext) async throws -> NodeResult<CoverageState> in
            .dictionary(["note": "hi"])
        }
        builder.addReducer(forKey: "note") { state, value in
            state.message = value
        }
        builder.setEntryPoint("emit")
        builder.addEdge(from: "emit", to: EndNode.id)
        let result = try await builder.compile().invoke(initialState: CoverageState())
        #expect(result.message == "hi")
    }

    @Test("Branch edge routes to mapped target and default")
    func branchEdgeRouting() async throws {
        func graph(flag: String) throws -> Graph<CoverageState> {
            let builder = GraphBuilder<CoverageState>()
            builder.addNode("route") { _ in CoverageState(message: flag) }
            builder.addNode("fast") { _ in CoverageState(message: "fast") }
            builder.addNode("slow") { _ in CoverageState(message: "slow") }
            builder.setEntryPoint("route")
            builder.addBranchEdge(from: "route", path: { $0.message }, mapping: ["fast": "fast"], defaultTarget: "slow")
            builder.addEdge(from: "fast", to: EndNode.id)
            builder.addEdge(from: "slow", to: EndNode.id)
            return try builder.compile()
        }
        #expect(try await graph(flag: "fast").invoke().message == "fast")
        #expect(try await graph(flag: "other").invoke().message == "slow")
    }

    @Test("Stream emits started and completed lifecycle events")
    func streamLifecycleEvents() async throws {
        let graph = try singleStepGraph()
        var sawStarted = false
        var sawCompleted = false
        for try await event in graph.stream(initialState: CoverageState()) {
            switch event {
            case .started: sawStarted = true
            case .completed(let state, let steps):
                sawCompleted = true
                #expect(state.count == 1)
                #expect(steps == 1)
            default: break
            }
        }
        #expect(sawStarted && sawCompleted)
    }

    @Test("Checkpointer integration saves records during invoke")
    func checkpointerIntegration() async throws {
        let checkpointer = InMemoryCheckpointer()
        let graph = try singleStepGraph(checkpointer: checkpointer)
        let threadId = "thread-checkpoint-1"
        _ = try await graph.invoke(initialState: CoverageState(), threadId: threadId)
        let history = try await checkpointer.getHistory(threadId: threadId)
        #expect(history.count >= 2)
    }

    // MARK: - Compile-time validation errors

    @Test("Empty node identifier fails compilation")
    func emptyNodeIdFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("   ") { state in state }
        builder.setEntryPoint("   ")
        builder.addEdge(from: "   ", to: EndNode.id)
        #expect(throws: GraphError.self) { try builder.compile() }
    }

    @Test("Duplicate node registration fails compilation")
    func duplicateNodeFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("dup") { state in state }
        builder.addNode("dup") { state in state }
        builder.setEntryPoint("dup")
        builder.addEdge(from: "dup", to: EndNode.id)
        #expect(throws: GraphError.self) { try builder.compile() }
    }

    @Test("Missing entry point fails compilation")
    func missingEntryPointFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.addEdge(from: "a", to: EndNode.id)
        #expect(throws: GraphError.self) { try builder.compile() }
    }

    @Test("Entry point referencing unknown node fails compilation")
    func unknownEntryPointFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.setEntryPoint("ghost")
        #expect(throws: GraphError.self) { try builder.compile() }
    }

    @Test("Edge referencing unknown node fails compilation")
    func unknownEdgeTargetFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.setEntryPoint("a")
        builder.addEdge(from: "a", to: "ghost")
        #expect(throws: GraphError.self) { try builder.compile() }
    }

    @Test("Non-positive maxRecursionDepth fails compilation")
    func zeroRecursionDepthFails() {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.setEntryPoint("a")
        builder.addEdge(from: "a", to: EndNode.id)
        #expect(throws: GraphError.self) { try builder.compile(maxRecursionDepth: 0) }
    }

    // MARK: - Boundary cases

    @Test("Recursion depth of one allows a single-step graph")
    func recursionDepthOneBoundary() async throws {
        let result = try await singleStepGraph(maxRecursionDepth: 1).invoke(initialState: CoverageState())
        #expect(result.count == 1)
    }

    @Test("Cyclic graph exceeding recursion limit throws")
    func recursionLimitExceeded() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("loop") { state in
            var next = state
            next.count += 1
            return next
        }
        builder.setEntryPoint("loop")
        builder.addConditionalEdge(from: "loop") { _ in "loop" }
        let graph = try builder.compile(maxRecursionDepth: 3)
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: CoverageState())
        }
    }

    @Test("Unresolved branch without default throws at runtime")
    func unresolvedBranchThrows() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("route") { _ in CoverageState(message: "unknown-key") }
        builder.setEntryPoint("route")
        builder.addBranchEdge(from: "route", path: { $0.message }, mapping: ["known": EndNode.id])
        let graph = try builder.compile()
        await #expect(throws: GraphError.self) {
            try await graph.invoke(initialState: CoverageState())
        }
    }

    @Test("Conditional edge returning unknown node throws nodeNotFound")
    func conditionalUnknownNodeThrows() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.setEntryPoint("a")
        builder.addConditionalEdge(from: "a") { _ in "ghost-node" }
        let graph = try builder.compile()
        do {
            _ = try await graph.invoke(initialState: CoverageState())
            Issue.record("Expected nodeNotFound error")
        } catch let error as GraphError {
            #expect(error == .nodeNotFound(nodeId: "ghost-node"))
        }
    }

    @Test("Throwing node propagates the original error")
    func throwingNodePropagates() async throws {
        struct Boom: Error {}
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("boom") { (_: CoverageState) async throws -> CoverageState in throw Boom() }
        builder.setEntryPoint("boom")
        builder.addEdge(from: "boom", to: EndNode.id)
        let graph = try builder.compile()
        await #expect(throws: Boom.self) {
            try await graph.invoke(initialState: CoverageState())
        }
    }

    @Test("Throwing conditional edge propagates the error")
    func throwingConditionPropagates() async throws {
        struct CondBoom: Error {}
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("a") { state in state }
        builder.setEntryPoint("a")
        builder.addConditionalEdge(from: "a") { (_: CoverageState) async throws -> String in throw CondBoom() }
        let graph = try builder.compile()
        await #expect(throws: CondBoom.self) {
            try await graph.invoke(initialState: CoverageState())
        }
    }

    // MARK: - Interrupts

    @Test("GraphInterrupt in node surfaces as interrupted error from invoke")
    func interruptSurfacesFromInvoke() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("gate") { (_: CoverageState, _: ExecutionContext) async throws -> NodeResult<CoverageState> in
            throw GraphInterrupt.approvalRequired(message: "Need approval", actionName: "delete")
        }
        builder.setEntryPoint("gate")
        builder.addEdge(from: "gate", to: EndNode.id)
        let graph = try builder.compile()
        do {
            _ = try await graph.invoke(initialState: CoverageState(), threadId: "t-interrupt")
            Issue.record("Expected interrupted error")
        } catch let error as GraphError {
            #expect(error == .interrupted(message: "Need approval", threadId: "t-interrupt"))
        }
    }

    @Test("Stream yields an interrupted event")
    func streamYieldsInterruptedEvent() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("gate") { (_: CoverageState, _: ExecutionContext) async throws -> NodeResult<CoverageState> in
            throw GraphInterrupt.clarification(question: "Which one?")
        }
        builder.setEntryPoint("gate")
        builder.addEdge(from: "gate", to: EndNode.id)
        var sawInterrupt = false
        for try await event in try builder.compile().stream(initialState: CoverageState()) {
            if case .interrupted(let interrupt, _, let nodeId) = event {
                sawInterrupt = true
                #expect(interrupt.message == "Which one?")
                #expect(interrupt.isApprovalRequired == false)
                #expect(nodeId == "gate")
            }
        }
        #expect(sawInterrupt)
    }

    @Test("InterruptManager tracks and clears pending interrupts")
    func interruptManagerLifecycle() async throws {
        let manager = InterruptManager()
        #expect(await manager.getPending(threadId: "t1") == nil)
        await manager.register(threadId: "t1", interrupt: GraphInterrupt(message: "hold"))
        #expect(await manager.getPending(threadId: "t1")?.message == "hold")
        await manager.clear(threadId: "t1")
        #expect(await manager.getPending(threadId: "t1") == nil)
    }

    // MARK: - Cancellation

    @Test("Cancelled invoke stops promptly without completing")
    func invokeCancellationStopsPromptly() async throws {
        let builder = GraphBuilder<CoverageState>()
        builder.addNode("slow") { state in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            var next = state
            next.count = 99
            return next
        }
        builder.setEntryPoint("slow")
        builder.addEdge(from: "slow", to: EndNode.id)
        let graph = try builder.compile()
        let start = Date()
        var completedNormally = false
        do {
            let final = try await withThrowingTaskGroup(of: CoverageState.self) { group in
                group.addTask { try await graph.invoke(initialState: CoverageState()) }
                try await Task.sleep(nanoseconds: 100_000_000)
                group.cancelAll()
                var last: CoverageState?
                for try await value in group { last = value }
                return last ?? CoverageState(count: -1)
            }
            completedNormally = (final.count == 99)
        } catch is CancellationError {
            completedNormally = false
        }
        #expect(!completedNormally)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    // MARK: - AgentState, AnySendable, DictionaryState

    @Test("AnySendable round-trips scalar and nested values")
    func anySendableRoundTrip() throws {
        let values: [AnySendable] = [
            AnySendable(true),
            AnySendable(42),
            AnySendable(3.5),
            AnySendable("text"),
            AnySendable([AnySendable(1), AnySendable("two")]),
            AnySendable(["k": AnySendable("v")]),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AnySendable.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("AnySendable rejects unsupported JSON and unequal values compare false")
    func anySendableEdgeCases() throws {
        #expect(AnySendable(1) != AnySendable(2))
        #expect(AnySendable("a") != AnySendable(1))
        let nullData = "null".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AnySendable.self, from: nullData)
        }
    }

    @Test("DictionaryState subscript sets and removes values")
    func dictionaryStateSubscript() {
        var state = DictionaryState()
        #expect(state["missing"] == nil)
        state["k"] = "v"
        #expect(state["k"] == "v")
        state["k"] = nil
        #expect(state["k"] == nil)
        #expect(DictionaryState() == DictionaryState())
    }

    @Test("EmptyState encodes as an empty object")
    func emptyStateCodable() throws {
        let data = try JSONEncoder().encode(EmptyState())
        let decoded = try JSONDecoder().decode(EmptyState.self, from: data)
        #expect(decoded == EmptyState())
    }

    // MARK: - Reducers

    @Test("AppendReducer appends elements")
    func appendReducer() {
        var state = CoverageState()
        AppendReducer<CoverageState, String>(keyPath: \.items).reduce(state: &state, update: ["a"])
        AppendReducer<CoverageState, String>(keyPath: \.items).reduce(state: &state, update: [])
        AppendReducer<CoverageState, String>(keyPath: \.items).reduce(state: &state, update: ["b", "c"])
        #expect(state.items == ["a", "b", "c"])
    }

    @Test("OverwriteReducer replaces the field")
    func overwriteReducer() {
        var state = CoverageState(message: "old")
        OverwriteReducer<CoverageState, String>(keyPath: \.message).reduce(state: &state, update: "new")
        #expect(state.message == "new")
    }

    @Test("MergeDictionaryReducer merges with new-wins")
    func mergeDictionaryReducer() {
        var state = CoverageState(scores: ["a": 1])
        MergeDictionaryReducer<CoverageState, String, Int>(keyPath: \.scores)
            .reduce(state: &state, update: ["a": 2, "b": 3])
        #expect(state.scores == ["a": 2, "b": 3])
    }

    @Test("NumericAddReducer accumulates including negatives")
    func numericAddReducer() {
        var state = CoverageState()
        let reducer = NumericAddReducer<CoverageState, Int>(keyPath: \.total)
        reducer.reduce(state: &state, update: 5)
        reducer.reduce(state: &state, update: 0)
        reducer.reduce(state: &state, update: -2)
        #expect(state.total == 3)
    }

    @Test("AnyReducer applies a custom closure")
    func anyReducerCustom() {
        var state = CoverageState()
        let reducer = AnyReducer<CoverageState, Int> { state, update in
            state.total = update * 2
        }
        reducer.reduce(state: &state, update: 21)
        #expect(state.total == 42)
    }

    // MARK: - Model types

    @Test("ModelCapabilities presets and withStreaming")
    func modelCapabilities() {
        #expect(ModelCapabilities.appleFoundation.isOnDevice)
        #expect(!ModelCapabilities.cloudStandard.isOnDevice)
        #expect(!ModelCapabilities.mlxLocal.supportsJSONSchema)
        let noStream = ModelCapabilities.cloudStandard.withStreaming(false)
        #expect(!noStream.supportsStreaming)
        #expect(noStream.maxContextTokens == ModelCapabilities.cloudStandard.maxContextTokens)
    }

    @Test("ModelPricing calculates cost with cached clamp at zero")
    func modelPricingCost() {
        let pricing = ModelPricing(modelId: "test", inputCostPer1M: 1.0, outputCostPer1M: 2.0, cachedInputCostPer1M: 0.5)
        #expect(pricing.calculateCost(promptTokens: 0, completionTokens: 0) == 0.0)
        #expect(pricing.calculateCost(promptTokens: 1_000_000, completionTokens: 1_000_000) == 3.0)
        let cachedHeavy = pricing.calculateCost(promptTokens: 100, completionTokens: 0, cachedTokens: 500)
        #expect(cachedHeavy == (Double(500) / 1_000_000.0) * 0.5)
    }

    @Test("GenerationOptions and response defaults")
    func generationDefaults() {
        let options = GenerationOptions()
        #expect(options.temperature == 0.7)
        #expect(options.stopSequences.isEmpty)
        #expect(options.responseFormatJSON == false)
        let response = ModelResponse(text: "hi")
        #expect(response.toolCalls.isEmpty)
        #expect(response.finishReason == "stop")
        #expect(response.usage == nil)
        #expect(TokenUsage().totalTokens == 0)
        #expect(ModelResponseChunk().isFinished == false)
    }

    @Test("ChatMessage factories assign roles")
    func chatMessageFactories() {
        #expect(ChatMessage.system("s").role == .system)
        #expect(ChatMessage.user("u").role == .user)
        #expect(ChatMessage.assistant("a").role == .assistant)
        #expect(ChatMessage.toolResult("r", toolCallId: "c1").role == .tool)
        #expect(ChatMessage.toolResult("r", toolCallId: "c1").toolCallId == "c1")
    }

    // MARK: - Persistence

    @Test("InMemoryCheckpointer returns nil history for unknown thread")
    func checkpointerEmptyThread() async throws {
        let checkpointer = InMemoryCheckpointer()
        #expect(try await checkpointer.getHistory(threadId: "nope").isEmpty)
        #expect(try await checkpointer.getLatest(threadId: "nope", as: CoverageState.self) == nil)
    }

    @Test("InMemoryCheckpointer fork copies state to a new thread")
    func checkpointerFork() async throws {
        let checkpointer = InMemoryCheckpointer()
        let record = CheckpointRecord(threadId: "t1", nodeId: "n", stepIndex: 0, state: CoverageState(count: 3))
        try await checkpointer.save(record: record)
        let forked = try await checkpointer.fork(threadId: "t1", fromCheckpointId: record.checkpointId, newThreadId: "t2")
        #expect(forked.threadId == "t2")
        let latest = try await checkpointer.getLatest(threadId: "t2", as: CoverageState.self)
        #expect(latest?.state.count == 3)
        try await checkpointer.deleteThread(threadId: "t2")
        #expect(try await checkpointer.getHistory(threadId: "t2").isEmpty)
    }

    @Test("InMemoryCheckpointer fork of missing checkpoint throws")
    func checkpointerForkMissing() async throws {
        let checkpointer = InMemoryCheckpointer()
        await #expect(throws: GraphError.self) {
            try await checkpointer.fork(threadId: "t1", fromCheckpointId: "missing", newThreadId: "t2")
        }
    }

    @Test("Resume without checkpointer throws graphHalted")
    func resumeWithoutCheckpointerThrows() async throws {
        let graph = try singleStepGraph()
        await #expect(throws: GraphError.self) {
            try await graph.resume(threadId: "any")
        }
    }

    // MARK: - GraphError policy surface

    @Test("GraphError descriptions are non-empty and equatable")
    func graphErrorDescriptions() {
        let errors: [GraphError] = [
            .nodeNotFound(nodeId: "x"),
            .entryPointNotSet,
            .recursionLimitExceeded(limit: 1, currentNodeId: "x"),
            .missingCondition(nodeId: "x"),
            .unresolvedBranch(from: "a", key: "k"),
            .invalidGraph(["bad"]),
            .graphHalted(reason: "halt"),
            .interrupted(message: "m", threadId: "t"),
            .stateDeserializationFailed("s"),
            .zeroCloudViolation("v"),
            .toolExecutionFailed(toolName: "tool", errorDescription: "boom"),
        ]
        for error in errors {
            #expect(!(error.errorDescription?.isEmpty ?? true))
        }
        #expect(GraphError.entryPointNotSet == .entryPointNotSet)
        #expect(GraphError.entryPointNotSet != .graphHalted(reason: "x"))
    }
}
