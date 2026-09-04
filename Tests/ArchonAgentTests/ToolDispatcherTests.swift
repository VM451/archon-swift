import Testing
import Foundation
@testable import ArchonAgent

@Suite("Tool Dispatcher Tests")
struct ToolDispatcherTests {

    @Test("CalculatorTool evaluates arithmetic string correctly")
    func testCalculatorTool() async throws {
        let calc = CalculatorTool()
        let result = try await calc.call(argumentsJSON: "{\"expression\": \"15 * 4 + 10\"}")
        #expect(result.contains("70") || result.contains("70.0"))
    }

    @Test("FileSystemTool reads and writes within temporary sandbox")
    func testFileSystemTool() async throws {
        let fs = FileSystemTool()
        let filename = "test_archon_\(UUID().uuidString).txt"
        let writeJson = "{\"action\": \"write\", \"path\": \"\(filename)\", \"content\": \"Hello ArchonAgent\"}"
        _ = try await fs.call(argumentsJSON: writeJson)

        let readJson = "{\"action\": \"read\", \"path\": \"\(filename)\"}"
        let readContent = try await fs.call(argumentsJSON: readJson)
        #expect(readContent == "Hello ArchonAgent")
    }

    @Test("ToolDispatcher handles missing tools gracefully")
    func testToolDispatcherMissingTool() async {
        let dispatcher = ToolDispatcher()
        let call = ToolCall(name: "nonExistentTool", arguments: "{}")
        let result = await dispatcher.execute(call: call)

        #expect(result.content.contains("is not registered"))
    }

    @Test("ToolDispatcher requires an explicit grant for side-effect tools")
    func testToolAuthorizationPolicy() async {
        let registry = ToolRegistry()
        registry.register(FileSystemTool())
        let denied = await ToolDispatcher(registry: registry).execute(
            call: ToolCall(name: "fileSystem", arguments: "{\"action\":\"list\",\"path\":\".\"}"))
        #expect(denied.content.contains("Authorization required"))

        let allowed = await ToolDispatcher(
            registry: registry,
            authorizationPolicy: ToolAuthorizationPolicy(allowedToolNames: ["fileSystem"])
        ).execute(call: ToolCall(name: "fileSystem", arguments: "{\"action\":\"list\",\"path\":\".\"}"))
        #expect(!allowed.content.contains("Authorization required"))
    }

    @Test("ToolDispatcher validates required fields and primitive types")
    func testToolSchemaValidation() async {
        let registry = ToolRegistry()
        registry.register(ClosureTool(
            name: "needsText",
            description: "Requires a text value.",
            parametersSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "text": AnySendable(["type": AnySendable("string")])
                ]),
                "required": AnySendable([AnySendable("text")])
            ]
        ) { _ in "called" })

        let dispatcher = ToolDispatcher(registry: registry)
        let missing = await dispatcher.execute(call: ToolCall(name: "needsText", arguments: "{}"))
        #expect(missing.content.contains("missing required field"))

        let wrongType = await dispatcher.execute(call: ToolCall(name: "needsText", arguments: "{\"text\":42}"))
        #expect(wrongType.content.contains("must be string"))

        let valid = await dispatcher.execute(call: ToolCall(name: "needsText", arguments: "{\"text\":\"ok\"}"))
        #expect(valid.content == "called")
    }

    @Test("Checkpoint state protection encrypts and round-trips state")
    func testCheckpointStateProtection() throws {
        let plaintext = Data("private agent state".utf8)
        let sealed = try CheckpointStateProtector.seal(plaintext)
        #expect(sealed != plaintext)
        #expect(try CheckpointStateProtector.open(sealed) == plaintext)
    }
}

@Suite("Multi-Agent & Subgraph Tests")
struct MultiAgentTests {

    @Test("SubgraphNode invokes child graph and maps state back to parent")
    func testSubgraphNodeExecution() async throws {
        // Child Graph
        let childBuilder = GraphBuilder<SimpleAgentState>()
        childBuilder.addNode("childWorker") { state in
            var s = state
            s.count += 50
            return s
        }
        childBuilder.setEntryPoint("childWorker")
        childBuilder.addEdge(from: "childWorker", to: EndNode.id)
        let childGraph = childBuilder.compile()

        // Parent Graph
        let parentBuilder = GraphBuilder<PersistentState>()
        let subNode = SubgraphNode<PersistentState, SimpleAgentState>(
            id: "subAgent",
            childGraph: childGraph,
            stateToChild: { parent in SimpleAgentState(count: parent.step) },
            childToState: { parent, child in parent.step = child.count }
        )

        parentBuilder.addNode(subNode)
        parentBuilder.setEntryPoint("subAgent")
        parentBuilder.addEdge(from: "subAgent", to: EndNode.id)

        let parentGraph = parentBuilder.compile()
        let finalState = try await parentGraph.invoke(initialState: PersistentState(step: 10, data: "start"))

        #expect(finalState.step == 60)
    }

    @Test("ParallelNode executes concurrent branches via task group")
    func testParallelNodeExecution() async throws {
        let parallel = ParallelNode<SimpleAgentState>(
            id: "parallelWorker",
            branches: [
                { state, _ in SimpleAgentState(count: state.count + 10) },
                { state, _ in SimpleAgentState(count: state.count + 20) }
            ],
            reducer: { state, results in
                for r in results {
                    state.count += r.count
                }
            }
        )

        let builder = GraphBuilder<SimpleAgentState>()
        builder.addNode(parallel)
        builder.setEntryPoint("parallelWorker")
        builder.addEdge(from: "parallelWorker", to: EndNode.id)

        let graph = builder.compile()
        let res = try await graph.invoke(initialState: SimpleAgentState(count: 0))

        #expect(res.count == 30)
    }
}

@Suite("Security Guardrails & PII Sanitizer Tests")
struct SecurityGuardrailsTests {

    @Test("ZeroCloudMode throws when active and external provider is invoked")
    func testZeroCloudModeEnforcement() async throws {
        ZeroCloudMode.isEnabled = true
        defer { ZeroCloudMode.isEnabled = false }

        let provider = OpenAIProvider(apiKey: "fake-key")

        await #expect(throws: GraphError.self) {
            _ = try await provider.generate(prompt: [ChatMessage.user("hello")])
        }
    }

    @Test("PIISanitizer redacts emails, phones, and SSNs")
    func testPIISanitizer() {
        let dirty = "Contact john.doe@company.com or call 415-555-2671 or check SSN 123-45-6789."
        let cleaned = PIISanitizer.sanitize(text: dirty)

        #expect(!cleaned.contains("john.doe@company.com"))
        #expect(cleaned.contains("[REDACTED_EMAIL]"))
        #expect(!cleaned.contains("415-555-2671"))
        #expect(cleaned.contains("[REDACTED_PHONE]"))
        #expect(!cleaned.contains("123-45-6789"))
        #expect(cleaned.contains("[REDACTED_SSN]"))
    }
}

@Suite("Concurrency & Thread Safety Stress Tests")
struct ConcurrencyStressTests {

    @Test("50 concurrent graph invocations execute safely without race conditions")
    func testConcurrentGraphInvocations() async throws {
        let builder = GraphBuilder<SimpleAgentState>()
        builder.addNode("worker") { state in
            var s = state
            s.count += 1
            return s
        }
        builder.setEntryPoint("worker")
        builder.addEdge(from: "worker", to: EndNode.id)
        let graph = builder.compile()

        try await withThrowingTaskGroup(of: SimpleAgentState.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try await graph.invoke(initialState: SimpleAgentState(count: i))
                }
            }

            var results: [SimpleAgentState] = []
            for try await res in group {
                results.append(res)
            }
            #expect(results.count == 50)
        }
    }
}
