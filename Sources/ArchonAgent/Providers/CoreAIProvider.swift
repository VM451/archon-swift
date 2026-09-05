import Foundation
import OSLog
import ArchonCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Target execution unit for Core AI hardware acceleration.
public enum CoreAIComputeUnit: String, Codable, Equatable, Sendable {
    /// Apple Neural Engine (ANE) first with GPU fallback for ultra-low power consumption.
    case neuralEngineFirst

    /// GPU first for maximum parallel throughput.
    case gpuFirst

    /// All available compute units (Neural Engine + GPU + CPU).
    case all
}

/// Model source specification for Apple Core AI compiled neural assets.
public enum CoreAIModelSource: Sendable, Equatable {
    /// A pre-compiled Core AI neural asset bundled with the application.
    case bundledAsset(named: String)

    /// A compiled Core AI model directory in the application sandbox.
    case localDirectory(URL)

    /// A logical model identifier that a consuming app must resolve to a URL-backed asset.
    case modelIdentifier(String)

    public var identifier: String {
        switch self {
        case .bundledAsset(let name):
            return "bundle://\(name)"
        case .localDirectory(let url):
            return url.path
        case .modelIdentifier(let id):
            return id
        }
    }
}

/// Errors raised by the Core AI execution provider.
public enum CoreAIProviderError: Error, LocalizedError, Sendable, Equatable {
    case modelNotFound(String)
    case invalidModelAsset(String)
    case compilationFailed(String)
    case functionNotFound(String)
    case contextWindowExceeded(Int, Int)
    case emptyPrompt
    case sourceUnsupported(String)
    case runtimeUnavailable(String)
    case memoryEstimateUnavailable
    case insufficientMemory(predictedPeakBytes: UInt64, availableBudgetBytes: UInt64)
    case textGenerationAdapterRequired
    case toolCallingUnsupported

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Core AI model asset '\(name)' could not be located."
        case .invalidModelAsset(let path):
            return "The Core AI asset at '\(path)' is not a valid public Core AI model asset."
        case .compilationFailed(let reason):
            return "Core AI model compilation/specialization failed: \(reason)"
        case .functionNotFound(let name):
            return "Core AI model function '\(name)' is not exported by the specialized asset."
        case .contextWindowExceeded(let current, let max):
            return "Core AI prompt context (\(current) tokens) exceeded limit (\(max) tokens)."
        case .emptyPrompt:
            return "Core AI generation requires at least one chat message."
        case .sourceUnsupported(let reason):
            return "Core AI model source is unsupported: \(reason)"
        case .runtimeUnavailable(let reason):
            return "Core AI runtime is unavailable: \(reason)"
        case .memoryEstimateUnavailable:
            return "Core AI model preparation is blocked because no peak-memory estimate was supplied. Register the model in an Archon catalog or ModelLibrary first."
        case .insufficientMemory(let predictedPeakBytes, let availableBudgetBytes):
            return "Core AI model preparation is blocked: predicted peak memory \(predictedPeakBytes) bytes exceeds the current safe model budget of \(availableBudgetBytes) bytes."
        case .textGenerationAdapterRequired:
            return "Core AI exposes tensor functions, not a universal text-generation contract; inject a model-specific tokenizer and text-generation adapter."
        case .toolCallingUnsupported:
            return "Dynamic Archon tool definitions cannot be executed without a concrete Core AI tool adapter."
        }
    }
}

/// Adapter boundary for model-specific Core AI text generation.
///
/// Core AI assets expose tensor functions. A text model still needs an
/// application-owned tokenizer, prompt template, sampling policy, KV-cache
/// handling, and output-token decoder. Implementations can use
/// `CoreAIModelRuntime.loadFunction` to execute the asset's public functions.
public protocol CoreAITextGenerationAdapter: Sendable {
    func generate(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse

    func stream(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit,
        runtime: CoreAIModelRuntime,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error>
}

/// Provider boundary for Apple's public Core AI framework (iOS 27+ and macOS 27+).
///
/// Asset validation, specialization, function discovery, and cache ownership
/// are implemented by `CoreAIModelRuntime`. Text generation remains explicit:
/// applications inject a `CoreAITextGenerationAdapter` for each model family.
/// This keeps model-specific tensor contracts honest and prevents synthetic
/// responses when a tokenizer or function mapping is missing.
public final class CoreAIProvider: LLMProvider, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.archon.agent.swift", category: "CoreAIProvider")

    public let id: String
    public let capabilities: ModelCapabilities
    public let modelSource: CoreAIModelSource
    public let computeUnit: CoreAIComputeUnit
    public let modelRuntime: CoreAIModelRuntime
    /// Predicted peak resident memory used before specializing a local asset.
    /// A missing estimate means preparation is refused until the asset is
    /// catalogued.
    public let predictedPeakMemoryBytes: UInt64?

    private let simulatedDelay: TimeInterval
    private let mockResponses: MockResponseStore
    private let textGenerationAdapter: (any CoreAITextGenerationAdapter)?

    /// Default Core AI provider configured for the Gemma 4 E2B compatibility
    /// seed on Neural Engine. Use an explicit `CoreAIModelSource` for another
    /// model family.
    public static let `default` = CoreAIProvider(
        model: "gemma-4-e2b.coreai",
        capabilities: ModelCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsVision: false,
            supportsJSONSchema: true,
            maxContextTokens: 8192,
            isOnDevice: true
        )
    )

    /// Whether Apple's Core AI runtime is available on the current device and OS.
    public static var isAvailable: Bool {
        ArchonDeviceCapabilities.current.supportsCoreAI
    }

    /// Creates a Core AI provider for a specific model asset name or identifier.
    public init(
        model: String = "gemma-4-e2b.coreai",
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst,
        capabilities: ModelCapabilities = .appleFoundation,
        simulatedDelay: TimeInterval = 0.01,
        mockResponses: [String: String] = [:],
        textGenerationAdapter: (any CoreAITextGenerationAdapter)? = nil,
        modelRuntime: CoreAIModelRuntime = CoreAIModelRuntime(),
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.id = "coreai.\(model)"
        self.modelSource = .modelIdentifier(model)
        self.computeUnit = computeUnit
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
            ?? (model == "gemma-4-e2b.coreai" ? 1_450 * 1_048_576 : nil)
        self.capabilities = capabilities
        self.simulatedDelay = simulatedDelay
        self.mockResponses = MockResponseStore(mockResponses)
        self.textGenerationAdapter = textGenerationAdapter
        self.modelRuntime = modelRuntime
    }

    /// Creates a Core AI provider from an explicit model source.
    public init(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst,
        capabilities: ModelCapabilities = .appleFoundation,
        simulatedDelay: TimeInterval = 0.01,
        mockResponses: [String: String] = [:],
        textGenerationAdapter: (any CoreAITextGenerationAdapter)? = nil,
        modelRuntime: CoreAIModelRuntime = CoreAIModelRuntime(),
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.id = "coreai.\(source.identifier)"
        self.modelSource = source
        self.computeUnit = computeUnit
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
        self.capabilities = capabilities
        self.simulatedDelay = simulatedDelay
        self.mockResponses = MockResponseStore(mockResponses)
        self.textGenerationAdapter = textGenerationAdapter
        self.modelRuntime = modelRuntime
    }

    /// Creates a Core AI provider configured for a specific Gemma variant.
    public convenience init(
        variant: GemmaVariant,
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst,
        simulatedDelay: TimeInterval = 0.01
    ) {
        let caps = ModelCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsVision: false,
            supportsJSONSchema: true,
            maxContextTokens: variant.maxContextTokens,
            isOnDevice: true
        )
        self.init(
            model: "\(variant.huggingFaceID.replacingOccurrences(of: "/", with: ".")).coreai",
            computeUnit: computeUnit,
            capabilities: caps,
            simulatedDelay: simulatedDelay,
            predictedPeakMemoryBytes: UInt64(max(0, variant.estimatedMemoryMB)) * 1_048_576
        )
    }

    /// Registers a mock response for deterministic offline testing.
    public func registerMockResponse(forPromptContaining substring: String, response: String) {
        mockResponses.set(response, for: substring)
    }

    /// Inspects the configured URL-backed Core AI asset without specializing it.
    public func inspectAsset() async throws -> CoreAIModelInspection {
        try await modelRuntime.inspect(source: modelSource)
    }

    /// Specializes and caches the configured asset using the selected compute unit.
    public func prepare() async throws -> CoreAIModelInspection {
        try validateMemoryBudget()
        return try await modelRuntime.prepare(source: modelSource, computeUnit: computeUnit)
    }

    /// Releases the specialized asset from the shared Core AI runtime cache.
    public func unload() async {
        await modelRuntime.unload(source: modelSource)
    }

    private func validateMemoryBudget() throws {
        guard let predictedPeakMemoryBytes, predictedPeakMemoryBytes > 0 else {
            throw CoreAIProviderError.memoryEstimateUnavailable
        }
        let availableBudgetBytes = ArchonDeviceCapabilities.current.recommendedModelMemoryBytes
        guard predictedPeakMemoryBytes <= availableBudgetBytes else {
            throw CoreAIProviderError.insufficientMemory(
                predictedPeakBytes: predictedPeakMemoryBytes,
                availableBudgetBytes: availableBudgetBytes
            )
        }
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        guard !prompt.isEmpty else {
            throw CoreAIProviderError.emptyPrompt
        }

        let fullPromptText = prompt.map(\.content).joined(separator: "\n")

        guard tools.isEmpty || textGenerationAdapter != nil else {
            throw CoreAIProviderError.toolCallingUnsupported
        }

        if let response = mockResponses.response(for: fullPromptText, caseSensitive: true) {
            return ModelResponse(
                text: response,
                finishReason: "stop",
                usage: TokenUsage(promptTokens: 25, completionTokens: 35, totalTokens: 60)
            )
        }

        if simulatedDelay > 0 {
            try await Task.sleep(for: .seconds(simulatedDelay))
        }

        if let textGenerationAdapter {
            return try await textGenerationAdapter.generate(
                source: modelSource,
                computeUnit: computeUnit,
                runtime: modelRuntime,
                prompt: prompt,
                tools: tools,
                options: options
            )
        }

        throw CoreAIProviderError.textGenerationAdapterRequired
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        if let textGenerationAdapter {
            return textGenerationAdapter.stream(
                source: modelSource,
                computeUnit: computeUnit,
                runtime: modelRuntime,
                prompt: prompt,
                tools: tools,
                options: options
            )
        }

        return AsyncThrowingStream<ModelResponseChunk, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    let response = try await self.generate(prompt: prompt, tools: tools, options: options)
                    let words = response.text.split(separator: " ").map(String.init)

                    for word in words {
                        try Task.checkCancellation()
                        continuation.yield(ModelResponseChunk(deltaText: word + " "))
                        if self.simulatedDelay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(self.simulatedDelay * 400_000_000))
                        }
                    }

                    if !response.toolCalls.isEmpty {
                        let toolChunks = response.toolCalls.enumerated().map { index, call in
                            ToolCallChunk(
                                index: index,
                                id: call.id,
                                name: call.name,
                                argumentsDelta: call.arguments
                            )
                        }
                        continuation.yield(ModelResponseChunk(toolCallChunks: toolChunks))
                    }

                    continuation.yield(ModelResponseChunk(isFinished: true))
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
}
