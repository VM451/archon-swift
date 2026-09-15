import Foundation
import Testing
@testable import ArchonAgent

// MARK: - Fakes

private struct FakeAppleRuntime: AppleFoundationModelRuntime, Sendable {
    var isAvailable: Bool = true
    var response: AppleFoundationModelRuntimeResponse
    var streamChunks: [String] = ["hello"]

    func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AppleFoundationModelRuntimeResponse {
        response
    }

    func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        let chunks = streamChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class AdapterCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
}

private struct CountingCoreAIAdapter: CoreAITextGenerationAdapter {
    let counter: AdapterCallCounter

    func generate(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        counter.increment()
        return ModelResponse(text: "adapter response")
    }

    func stream(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            continuation.yield(ModelResponseChunk(deltaText: "adapter response"))
            continuation.yield(ModelResponseChunk(isFinished: true))
            continuation.finish()
        }
    }
}

private func tinyCaps(_ maxContext: Int) -> ModelCapabilities {
    ModelCapabilities(
        supportsStreaming: true,
        supportsToolCalling: true,
        supportsVision: false,
        supportsJSONSchema: false,
        maxContextTokens: maxContext,
        isOnDevice: true
    )
}

// MARK: - Shared validation

@Suite("Local Request Validation Tests")
struct LocalRequestValidationTests {
    @Test("Token estimate is deterministic and conservative")
    func estimateIsDeterministic() {
        let prompt: [ChatMessage] = [.user("hello world")]
        let first = LocalRequestValidation.estimatedTokenCount(for: prompt)
        let second = LocalRequestValidation.estimatedTokenCount(for: prompt)
        #expect(first == second)
        // 11 chars + 8 framing = 19 -> ceil(19/4) = 5
        #expect(first == 5)
    }

    @Test("Blank prompts are effectively empty")
    func blankPromptsAreEmpty() {
        #expect(LocalRequestValidation.isEffectivelyEmpty([]))
        #expect(LocalRequestValidation.isEffectivelyEmpty([.user("   ")]))
        #expect(!LocalRequestValidation.isEffectivelyEmpty([.user("  hi  ")]))
    }

    @Test("Invalid generation options are reported")
    func invalidOptionsReported() {
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions()) == nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(maxTokens: 0)) != nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(maxTokens: -5)) != nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(temperature: .nan)) != nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(temperature: 3)) != nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(topP: 1.5)) != nil)
        #expect(LocalRequestValidation.optionsProblem(GenerationOptions(topP: .infinity)) != nil)
    }
}

// MARK: - Apple provider

@Suite("Apple Foundation Model Hardening Tests")
struct AppleFoundationHardeningTests {
    @Test("Runtime usage totals are normalized to prompt + completion")
    func usageTotalsNormalized() async throws {
        let provider = AppleFoundationModelProvider(
            capabilities: .appleFoundation,
            runtime: FakeAppleRuntime(
                response: AppleFoundationModelRuntimeResponse(
                    text: "hi",
                    usage: TokenUsage(promptTokens: 10, completionTokens: 5)
                )
            )
        )
        let response = try await provider.generate(prompt: [.user("hello")])
        #expect(response.usage?.promptTokens == 10)
        #expect(response.usage?.completionTokens == 5)
        #expect(response.usage?.totalTokens == 15)
    }

    @Test("Oversized prompt fails closed before the system model is called")
    func contextWindowExceededBeforeRuntime() async {
        let provider = AppleFoundationModelProvider(
            capabilities: tinyCaps(4),
            runtime: FakeAppleRuntime(
                response: AppleFoundationModelRuntimeResponse(text: "must not reach here")
            )
        )
        await #expect(throws: AppleFoundationModelError.contextWindowExceeded) {
            _ = try await provider.generate(prompt: [.user("this prompt is far too long for four tokens")])
        }
    }

    @Test("Invalid options fail closed on generate and stream")
    func invalidOptionsFailClosed() async {
        let provider = AppleFoundationModelProvider(
            mockResponses: ["hello": "hi"],
            runtime: FakeAppleRuntime(response: AppleFoundationModelRuntimeResponse(text: "x"))
        )
        do {
            _ = try await provider.generate(
                prompt: [.user("hello")],
                tools: [],
                options: GenerationOptions(maxTokens: 0)
            )
            Issue.record("Expected invalidOptions.")
        } catch let error as AppleFoundationModelError {
            guard case .invalidOptions = error else {
                Issue.record("Unexpected Apple error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        await #expect(throws: AppleFoundationModelError.self) {
            for try await _ in provider.stream(
                prompt: [.user("hello")],
                tools: [],
                options: GenerationOptions(temperature: .nan)
            ) {}
        }
    }

    @Test("Whitespace-only prompt fails closed on generate and stream")
    func whitespacePromptFailsClosed() async {
        let provider = AppleFoundationModelProvider(
            runtime: FakeAppleRuntime(response: AppleFoundationModelRuntimeResponse(text: "x"))
        )
        await #expect(throws: AppleFoundationModelError.emptyPrompt) {
            _ = try await provider.generate(prompt: [.user("   ")])
        }
        await #expect(throws: AppleFoundationModelError.emptyPrompt) {
            for try await _ in provider.stream(prompt: [.user("  ")]) {}
        }
    }

    @Test("Stream rejects oversized prompts without yielding")
    func streamRejectsOversizedPrompt() async {
        let provider = AppleFoundationModelProvider(
            capabilities: tinyCaps(4),
            runtime: FakeAppleRuntime(response: AppleFoundationModelRuntimeResponse(text: "x"))
        )
        var yielded = 0
        do {
            for try await _ in provider.stream(prompt: [.user("this prompt is far too long")]) {
                yielded += 1
            }
            Issue.record("Expected contextWindowExceeded.")
        } catch let error as AppleFoundationModelError {
            #expect(error == .contextWindowExceeded)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(yielded == 0)
    }
}

// MARK: - CoreAI provider

@Suite("Core AI Hardening Tests")
struct CoreAIHardeningTests {
    @Test("Whitespace-only prompt fails closed without an adapter")
    func whitespacePromptFailsClosed() async {
        let provider = CoreAIProvider(model: "test.coreai", simulatedDelay: 0)
        await #expect(throws: CoreAIProviderError.emptyPrompt) {
            _ = try await provider.generate(prompt: [.user("   ")])
        }
    }

    @Test("Invalid options fail closed before mock lookup")
    func invalidOptionsFailClosed() async {
        let provider = CoreAIProvider(model: "test.coreai", simulatedDelay: 0)
        provider.registerMockResponse(forPromptContaining: "hello", response: "mock")
        do {
            _ = try await provider.generate(
                prompt: [.user("hello")],
                tools: [],
                options: GenerationOptions(maxTokens: 0)
            )
            Issue.record("Expected invalidOptions.")
        } catch let error as CoreAIProviderError {
            guard case .invalidOptions = error else {
                Issue.record("Unexpected Core AI error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Oversized prompt reports current and maximum tokens")
    func contextWindowExceeded() async {
        let provider = CoreAIProvider(
            source: .modelIdentifier("tiny"),
            capabilities: tinyCaps(4),
            simulatedDelay: 0
        )
        do {
            _ = try await provider.generate(prompt: [.user("this prompt is far too long for four tokens")])
            Issue.record("Expected contextWindowExceeded.")
        } catch let error as CoreAIProviderError {
            guard case .contextWindowExceeded(let current, let max) = error else {
                Issue.record("Unexpected Core AI error: \(error)")
                return
            }
            #expect(max == 4)
            #expect(current > max)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Stream rejects tools without an adapter")
    func streamRejectsToolsWithoutAdapter() async {
        let provider = CoreAIProvider(model: "test.coreai", simulatedDelay: 0)
        let tool = ToolDefinition(name: "clock", description: "Reads the time", parametersJSONSchema: [:])
        await #expect(throws: CoreAIProviderError.toolCallingUnsupported) {
            for try await _ in provider.stream(prompt: [.user("hi")], tools: [tool], options: GenerationOptions()) {}
        }
    }

    @Test("Stream validates before delegating to the text adapter")
    func streamValidatesBeforeAdapter() async {
        let counter = AdapterCallCounter()
        let provider = CoreAIProvider(
            source: .modelIdentifier("test-model"),
            simulatedDelay: 0,
            textGenerationAdapter: CountingCoreAIAdapter(counter: counter)
        )
        await #expect(throws: CoreAIProviderError.emptyPrompt) {
            for try await _ in provider.stream(prompt: [.user("  ")]) {}
        }
        #expect(counter.count == 0)
    }
}

// MARK: - MLX provider

@Suite("MLX Request-Shape Hardening Tests")
struct MLXHardeningTests {
    @Test("Empty prompt fails closed before platform availability")
    func emptyPromptFirst() async {
        let provider = MLXLocalProvider()
        await #expect(throws: MLXLocalProviderError.emptyPrompt) {
            _ = try await provider.generate(prompt: [], tools: [], options: GenerationOptions())
        }
        await #expect(throws: MLXLocalProviderError.emptyPrompt) {
            _ = try await provider.generate(prompt: [.user("  ")], tools: [], options: GenerationOptions())
        }
    }

    @Test("Invalid options fail closed")
    func invalidOptionsFailClosed() async {
        let provider = MLXLocalProvider()
        do {
            _ = try await provider.generate(
                prompt: [.user("hello")],
                tools: [],
                options: GenerationOptions(maxTokens: 0)
            )
            Issue.record("Expected invalidOptions.")
        } catch let error as MLXLocalProviderError {
            guard case .invalidOptions = error else {
                Issue.record("Unexpected MLX error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Oversized prompt fails closed with current and maximum")
    func contextWindowExceeded() async {
        let provider = MLXLocalProvider(
            model: "example/tiny-model",
            capabilities: tinyCaps(4)
        )
        do {
            _ = try await provider.generate(prompt: [.user("this prompt is far too long for four tokens")])
            Issue.record("Expected contextWindowExceeded.")
        } catch let error as MLXLocalProviderError {
            guard case .contextWindowExceeded(let current, let max) = error else {
                Issue.record("Unexpected MLX error: \(error)")
                return
            }
            #expect(max == 4)
            #expect(current > max)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Stream validates request shape before loading")
    func streamValidatesShape() async {
        let provider = MLXLocalProvider()
        await #expect(throws: MLXLocalProviderError.emptyPrompt) {
            for try await _ in provider.stream(prompt: []) {}
        }
    }
}

// MARK: - On-device routing and catalog

@Suite("On-Device Routing Hardening Tests")
struct OnDeviceRoutingHardeningTests {
    @Test("Explicit Gemma fails closed when available headroom collapses")
    func explicitGemmaRespectsAvailableHeadroom() async {
        let pressured = DeviceHardwareProfile(
            platform: .macOS,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
            availableProcessMemoryBytes: 100 * 1024 * 1024,
            processorCount: 10,
            isAppleFoundationModelSupported: false
        )
        let provider = OnDeviceProvider(
            strategy: .gemma(GemmaModelCatalog.gemma4_e2b_4bit),
            hardwareProfile: pressured
        )
        #expect(provider.backend == .unavailable)
        await #expect(throws: AdaptiveModelSelectionError.self) {
            _ = try await provider.generate(prompt: [.user("hello")])
        }
        await #expect(throws: AdaptiveModelSelectionError.self) {
            for try await _ in provider.stream(prompt: [.user("hello")]) {}
        }
    }

    @Test("Explicit Gemma still routes on healthy hardware")
    func explicitGemmaRoutesWhenHealthy() {
        let provider = OnDeviceProvider(
            strategy: .gemma(GemmaModelCatalog.gemma4_e2b_4bit),
            hardwareProfile: .macAppleSilicon
        )
        #expect(provider.backend == .mlx)
        #expect(provider.selectedGemmaVariant == GemmaModelCatalog.gemma4_e2b_4bit)
    }

    @Test("Duplicate catalog identifiers keep the first entry deterministically")
    func duplicateIdentifiersKeepFirst() {
        func candidate(id: String, name: String) -> AdaptiveModelCandidate {
            AdaptiveModelCandidate(
                id: id,
                name: name,
                family: "Test",
                source: .mlx(
                    source: .huggingFace(id: "example/\(name)", revision: "main"),
                    extraEOSTokens: []
                ),
                estimatedMemoryBytes: 512 * 1024 * 1024,
                supportedPlatforms: [.macOS]
            )
        }
        let catalog = AdaptiveModelCatalog(candidates: [
            candidate(id: "dup", name: "first"),
            candidate(id: "dup", name: "second"),
        ])
        #expect(catalog.candidates.count == 1)
        #expect(catalog.candidates.first?.name == "first")
    }

    @Test("Unavailable adaptive backend fails closed on generate and stream")
    func unavailableBackendFailsClosed() async {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive, runtime: .preferMLX),
            hardwareProfile: .iPhone12Base,
            appleFoundationModelAvailable: false,
            catalog: AdaptiveModelCatalog(candidates: [])
        )
        #expect(provider.backend == .unavailable)
        await #expect(throws: AdaptiveModelSelectionError.self) {
            _ = try await provider.generate(prompt: [.user("hello")])
        }
        await #expect(throws: AdaptiveModelSelectionError.self) {
            for try await _ in provider.stream(prompt: [.user("hello")]) {}
        }
    }
}
