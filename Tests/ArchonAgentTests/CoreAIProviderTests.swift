import Foundation
import Testing
@testable import ArchonAgent

@Suite("Apple Core AI Provider & Multi-Runtime Tests")
struct CoreAIProviderTests {

    @Test("CoreAI provider initializes with Neural Engine capabilities")
    func coreAIInitialization() {
        let provider = CoreAIProvider(model: "gemma-4-e2b.coreai")

        #expect(provider.id == "coreai.gemma-4-e2b.coreai")
        #expect(provider.capabilities.isOnDevice)
        #expect(provider.capabilities.supportsStreaming)
        #expect(provider.capabilities.supportsToolCalling)
        #expect(provider.computeUnit == .neuralEngineFirst)
    }

    @Test("CoreAI provider supports explicit bundled assets and local directories")
    func modelSourceVariants() {
        let bundled = CoreAIProvider(source: .bundledAsset(named: "Gemma4NeuralAsset"))
        #expect(bundled.id == "coreai.bundle://Gemma4NeuralAsset")

        let localURL = URL(filePath: "/tmp/gemma.coreai")
        let localDir = CoreAIProvider(source: .localDirectory(localURL))
        #expect(localDir.id == "coreai./tmp/gemma.coreai")
    }

    @Test("CoreAI provider generates response and records token accounting")
    func coreAIGeneration() async throws {
        let provider = CoreAIProvider(model: "gemma-4-e2b.coreai")
        provider.registerMockResponse(
            forPromptContaining: "summarize",
            response: "Core AI on Neural Engine summarized the document."
        )

        let response = try await provider.generate(prompt: [
            .user("Please summarize this contract.")
        ])

        #expect(response.text == "Core AI on Neural Engine summarized the document.")
        #expect(response.finishReason == "stop")
        #expect(response.usage?.totalTokens ?? 0 > 0)
    }

    @Test("CoreAI provider streams delta chunks incrementally")
    func coreAIStreaming() async throws {
        let provider = CoreAIProvider(model: "gemma-4-e2b.coreai", simulatedDelay: 0.001)
        provider.registerMockResponse(
            forPromptContaining: "quantum",
            response: "Mock Core AI stream"
        )

        var streamedWords: [String] = []
        for try await chunk in provider.stream(prompt: [.user("Explain quantum computing")]) {
            if let delta = chunk.deltaText {
                streamedWords.append(delta)
            }
        }

        #expect(!streamedWords.isEmpty)
    }

    @Test("CoreAI provider rejects tools without a concrete runtime adapter")
    func coreAIToolDispatch() async {
        let provider = CoreAIProvider(model: "gemma-4-e2b.coreai")
        let calcTool = ToolDefinition(
            name: "calculate",
            description: "Evaluates math expression",
            parametersJSONSchema: [:]
        )

        await #expect(throws: CoreAIProviderError.self) {
            _ = try await provider.generate(
                prompt: [.user("Please calculate 42 * 100")],
                tools: [calcTool],
                options: GenerationOptions()
            )
        }
    }

    @Test("CoreAI throws emptyPrompt error on empty message history")
    func emptyPromptValidation() async {
        let provider = CoreAIProvider()

        await #expect(throws: CoreAIProviderError.self) {
            _ = try await provider.generate(prompt: [], tools: [], options: GenerationOptions())
        }
    }

    @Test("OnDeviceProvider routes to Core AI when runtime preference is preferCoreAI")
    func onDeviceRoutesToCoreAI() {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .balanced, runtime: .preferCoreAI),
            hardwareProfile: .iPhone14Pro
        )

        #expect(provider.backend == OnDeviceBackend.coreAI)
        #expect(provider.id.hasPrefix("coreai."))
        #expect(provider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("OnDeviceProvider routes to Core AI from explicit CoreAIModelSource")
    func onDeviceExplicitCoreAISource() {
        let provider = OnDeviceProvider(
            coreAISource: .bundledAsset(named: "Gemma4E4B")
        )

        #expect(provider.backend == OnDeviceBackend.coreAI)
        #expect(provider.id == "coreai.bundle://Gemma4E4B")
    }

    @Test("OnDeviceProvider static factory methods create properly configured instances")
    func staticFactoryMethods() {
        let speed = OnDeviceProvider.speedFirst()
        #expect(speed.capabilities.isOnDevice)

        let intelligence = OnDeviceProvider.intelligenceFirst()
        #expect(intelligence.capabilities.isOnDevice)

        let gemma = OnDeviceProvider.gemma(GemmaModelCatalog.gemma4_4b_4bit)
        #expect(gemma.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-4b-it-4bit")

        let coreAI = OnDeviceProvider.coreAI(model: "custom-llama.coreai")
        #expect(coreAI.backend == .coreAI)
        #expect(coreAI.id == "coreai.custom-llama.coreai")
    }

    @Test("CoreAI provider delegates text generation to an explicit model adapter")
    func explicitTextGenerationAdapter() async throws {
        let provider = CoreAIProvider(
            source: .modelIdentifier("test-model"),
            simulatedDelay: 0,
            textGenerationAdapter: TestCoreAITextGenerationAdapter()
        )

        let response = try await provider.generate(
            prompt: [.user("hello")],
            tools: [ToolDefinition(name: "clock", description: "Reads the time", parametersJSONSchema: [:])],
            options: GenerationOptions()
        )

        #expect(response.text == "adapter response")
        #expect(response.toolCalls.count == 1)
    }

    @Test("CoreAI provider fails closed without a text-generation adapter")
    func missingTextGenerationAdapter() async {
        let provider = CoreAIProvider(model: "unconfigured.coreai", simulatedDelay: 0)

        await #expect(throws: CoreAIProviderError.textGenerationAdapterRequired) {
            _ = try await provider.generate(prompt: [.user("hello")])
        }
    }

    @Test("CoreAI runtime rejects model identifiers before pretending to inspect an asset")
    func unsupportedModelIdentifier() async {
        let provider = CoreAIProvider(model: "catalog-model", simulatedDelay: 0)

        do {
            _ = try await provider.inspectAsset()
            Issue.record("A model identifier must not be treated as a URL-backed asset.")
        } catch let error as CoreAIProviderError {
            guard case .sourceUnsupported = error else {
                Issue.record("Unexpected Core AI error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private struct TestCoreAITextGenerationAdapter: CoreAITextGenerationAdapter {
    func generate(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        ModelResponse(
            text: "adapter response",
            toolCalls: tools.map { ToolCall(id: "call-1", name: $0.name, arguments: "{}") }
        )
    }

    func stream(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ModelResponseChunk(deltaText: "adapter response"))
            continuation.yield(ModelResponseChunk(isFinished: true))
            continuation.finish()
        }
    }
}
