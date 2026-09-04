import Testing
import Foundation
@testable import ArchonAgent

private struct TestFoundationRuntime: AppleFoundationModelRuntime {
    let response: String

    var isAvailable: Bool { true }

    func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AppleFoundationModelRuntimeResponse {
        AppleFoundationModelRuntimeResponse(
            text: "\(response) [\(systemInstructions ?? "no system instructions")]",
            usage: TokenUsage(promptTokens: 3, completionTokens: 5, totalTokens: 8)
        )
    }

    func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}

@Suite("Multi-Provider & Adapter Tests")
struct MultiProviderTests {

    @Test("Apple Foundation Model generates response offline")
    func testAppleFoundationModelGeneration() async throws {
        let provider = AppleFoundationModelProvider(id: "apple.foundation.test", simulatedDelay: 0.0)
        provider.registerMockResponse(forPromptContaining: "summarize", response: "Summary: ArchonAgent is fast.")

        let prompt = [ChatMessage.user("Please summarize ArchonAgent")]
        let response = try await provider.generate(prompt: prompt)

        #expect(response.text.contains("ArchonAgent is fast"))
        #expect(response.usage?.totalTokens ?? 0 > 0)
    }

    @Test("Apple Foundation Model provider delegates to the injected runtime")
    func delegatesToRuntime() async throws {
        let provider = AppleFoundationModelProvider(
            runtime: TestFoundationRuntime(response: "runtime response")
        )

        let response = try await provider.generate(prompt: [
            .system("Be concise."),
            .user("Explain actors.")
        ])

        #expect(response.text == "runtime response [Be concise.]")
        #expect(response.usage?.totalTokens == 8)
    }

    @Test("Apple Foundation Model rejects unrepresentable tool definitions")
    func testAppleFoundationModelRejectsUnrepresentableTools() async {
        let provider = AppleFoundationModelProvider(id: "apple.foundation.toolTest", simulatedDelay: 0.0)
        let tool = CalculatorTool()

        await #expect(throws: AppleFoundationModelError.self) {
            _ = try await provider.generate(
                prompt: [.user("Please call calculator with 5 + 5")],
                tools: [tool.definition],
                options: GenerationOptions()
            )
        }
    }
}

@Suite("Streaming Pipeline Tests")
struct StreamingTests {

    @Test("Graph.stream emits chronological lifecycle events")
    func testGraphStreamLifecycle() async throws {
        let builder = GraphBuilder<SimpleAgentState>()

        builder.addNode("step1") { state in
            var s = state
            s.count += 10
            return s
        }

        builder.setEntryPoint("step1")
        builder.addEdge(from: "step1", to: EndNode.id)

        let graph = builder.compile()
        var nodeCount = 0
        var isFinished = false

        for try await event in graph.stream(initialState: SimpleAgentState()) {
            switch event {
            case .nodeStarted(let id, _, _):
                #expect(id == "step1")
                nodeCount += 1
            case .completed(let state, _):
                #expect(state.count == 10)
                isFinished = true
            default:
                break
            }
        }

        #expect(nodeCount == 1)
        #expect(isFinished == true)
    }
}
