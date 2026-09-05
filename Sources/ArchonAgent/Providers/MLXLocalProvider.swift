import Foundation
import ArchonCore
import ArchonModels
import HuggingFace
#if canImport(MLXHuggingFace) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
#endif
import Tokenizers

/// A model source for an MLX language model.
public enum MLXModelSource: Sendable, Equatable {
    /// A model hosted on Hugging Face and downloaded on first use.
    case huggingFace(id: String, revision: String)

    /// A model directory already present in the app's sandbox or bundle.
    case localDirectory(URL)

    public var isLocal: Bool {
        switch self {
        case .huggingFace:
            false
        case .localDirectory:
            true
        }
    }

    public var identifier: String {
        switch self {
        case .huggingFace(let id, let revision):
            return "\(id)@\(revision)"
        case .localDirectory(let url):
            return url.path
        }
    }
}

/// Errors raised while preparing or evaluating an MLX model.
public enum MLXLocalProviderError: Error, LocalizedError, Sendable, Equatable {
    case emptyPrompt
    case memoryEstimateUnavailable
    case insufficientMemory(predictedPeakBytes: UInt64, availableBudgetBytes: UInt64)
    case unavailableOnPlatform

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "MLX generation requires at least one chat message."
        case .memoryEstimateUnavailable:
            return "MLX model loading is blocked because no peak-memory estimate was supplied. Register the model in an Archon catalog or ModelLibrary first."
        case .insufficientMemory(let predictedPeakBytes, let availableBudgetBytes):
            return "MLX model loading is blocked: predicted peak memory \(predictedPeakBytes) bytes exceeds the current safe model budget of \(availableBudgetBytes) bytes."
        case .unavailableOnPlatform:
            return "The MLX runtime is unavailable on this platform. Use an Apple Foundation Model, Core AI model, or a consuming app that links MLX Swift for this platform."
        }
    }
}

/// Local LLM provider backed by MLX Swift LM when the optional macOS runtime is linked.
///
/// The model is loaded lazily on the first request. The default is the
/// lightweight Gemma 4 E2B compatibility seed, while the initializer accepts
/// any compatible MLX model identifier or a local model directory. Each
/// request gets its own `ChatSession`, which keeps the provider safe for
/// concurrent graph invocations while the underlying `ModelContainer` remains
/// shared.
#if canImport(MLXHuggingFace) && canImport(MLXLLM) && canImport(MLXLMCommon)
public final class MLXLocalProvider: LLMProvider, @unchecked Sendable {
    /// A practical default for devices that cannot run Apple Foundation Models.
    public static let defaultModelID = "mlx-community/gemma-4-e2b-it-4bit"

    public let id: String
    public let capabilities: ModelCapabilities
    public let source: MLXModelSource
    /// Predicted peak resident memory used by the load gate. `nil` means the
    /// provider refuses to download or load until the source is catalogued.
    public let predictedPeakMemoryBytes: UInt64?

    private let configuration: MLXLMCommon.ModelConfiguration
    private let runtime: MLXModelRuntime

    /// Creates an MLX provider configured for a specific Gemma variant.
    public convenience init(
        variant: GemmaVariant,
        capabilities: ModelCapabilities? = nil
    ) {
        let caps = capabilities ?? ModelCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsVision: false,
            supportsJSONSchema: false,
            maxContextTokens: variant.maxContextTokens,
            isOnDevice: true
        )
        self.init(
            source: variant.asModelSource,
            capabilities: caps,
            extraEOSTokens: Set(variant.extraEOSTokens),
            predictedPeakMemoryBytes: UInt64(max(0, variant.estimatedMemoryMB)) * 1_048_576
        )
    }

    /// Creates an MLX provider for a Hugging Face model identifier.
    public convenience init(
        model: String = MLXLocalProvider.defaultModelID,
        revision: String = "main",
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String>? = nil
    ) {
        let eosTokens = extraEOSTokens ?? (
            model == MLXLocalProvider.defaultModelID ? ["<end_of_turn>"] : []
        )
        self.init(
            source: .huggingFace(id: model, revision: revision),
            capabilities: capabilities,
            extraEOSTokens: eosTokens,
            predictedPeakMemoryBytes: model == MLXLocalProvider.defaultModelID
                ? UInt64(GemmaModelCatalog.gemma4_e2b_4bit.estimatedMemoryMB) * 1_048_576
                : nil
        )
    }

    /// Creates an MLX provider for model files already stored locally.
    public convenience init(
        localModelDirectory: URL,
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String> = [],
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.init(
            source: .localDirectory(localModelDirectory),
            capabilities: capabilities,
            extraEOSTokens: extraEOSTokens,
            predictedPeakMemoryBytes: predictedPeakMemoryBytes
        )
    }

    /// Creates an MLX provider from an explicit remote or local source.
    public init(
        source: MLXModelSource,
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String> = [],
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.source = source
        self.capabilities = capabilities
        self.id = "mlx.\(source.identifier)"
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes

        switch source {
        case .huggingFace(let id, let revision):
            self.configuration = MLXLMCommon.ModelConfiguration(
                id: id,
                revision: revision,
                extraEOSTokens: extraEOSTokens
            )
        case .localDirectory(let directory):
            self.configuration = MLXLMCommon.ModelConfiguration(
                directory: directory,
                extraEOSTokens: extraEOSTokens
            )
        }

        self.runtime = MLXModelRuntime(source: source, configuration: configuration)
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        let request = try Self.makeRequest(prompt: prompt)
        try validateMemoryBudget()
        let model = try await runtime.modelContainer()
        let session = ChatSession(
            model,
            history: request.history,
            generateParameters: Self.generateParameters(from: options),
            tools: Self.toolSpecifications(from: tools)
        )

        var text = ""
        var toolCalls: [ToolCall] = []
        var usage: TokenUsage?

        for try await generation in session.streamDetails(
            to: request.lastMessage.content,
            role: request.lastMessage.role
        ) {
            try Task.checkCancellation()

            switch generation {
            case .chunk(let chunk):
                text += chunk
            case .toolCall(let call):
                toolCalls.append(Self.archonToolCall(from: call))
            case .info(let info):
                usage = TokenUsage(
                    promptTokens: info.promptTokenCount,
                    completionTokens: info.generationTokenCount,
                    totalTokens: info.promptTokenCount + info.generationTokenCount
                )
            }
        }

        return ModelResponse(
            text: Self.applyingStopSequences(to: text, options: options),
            toolCalls: toolCalls,
            finishReason: toolCalls.isEmpty ? "stop" : "tool_calls",
            usage: usage
        )
    }

    /// Eagerly loads the configured model into the shared MLX container.
    /// Model libraries can use this to separate warming from first-token latency.
    public func prepare() async throws {
        try validateMemoryBudget()
        _ = try await runtime.modelContainer()
    }

    /// Releases the cached MLX container and its model weights.
    public func unload() async {
        await runtime.unload()
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [runtime, prompt, tools, options] in
                do {
                    let request = try Self.makeRequest(prompt: prompt)
                    try validateMemoryBudget()
                    let model = try await runtime.modelContainer()
                    let session = ChatSession(
                        model,
                        history: request.history,
                        generateParameters: Self.generateParameters(from: options),
                        tools: Self.toolSpecifications(from: tools)
                    )

                    var toolCallIndex = 0
                    for try await generation in session.streamDetails(
                        to: request.lastMessage.content,
                        role: request.lastMessage.role
                    ) {
                        try Task.checkCancellation()

                        switch generation {
                        case .chunk(let chunk):
                            continuation.yield(ModelResponseChunk(deltaText: chunk))
                        case .toolCall(let call):
                            let toolCall = Self.archonToolCall(from: call)
                            continuation.yield(ModelResponseChunk(
                                toolCallChunks: [ToolCallChunk(
                                    index: toolCallIndex,
                                    id: toolCall.id,
                                    name: toolCall.name,
                                    argumentsDelta: toolCall.arguments
                                )]
                            ))
                            toolCallIndex += 1
                        case .info:
                            break
                        }
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

    private func validateMemoryBudget() throws {
        guard let predictedPeakMemoryBytes, predictedPeakMemoryBytes > 0 else {
            throw MLXLocalProviderError.memoryEstimateUnavailable
        }
        let availableBudgetBytes = ArchonDeviceCapabilities.current.recommendedModelMemoryBytes
        guard predictedPeakMemoryBytes <= availableBudgetBytes else {
            throw MLXLocalProviderError.insufficientMemory(
                predictedPeakBytes: predictedPeakMemoryBytes,
                availableBudgetBytes: availableBudgetBytes
            )
        }
    }
}

#else

/// API-compatible, fail-closed placeholder used on platforms where the optional
/// MLX Swift Metal package is not linked. It never fabricates inference.
public final class MLXLocalProvider: LLMProvider, @unchecked Sendable {
    public static let defaultModelID = "mlx-community/gemma-4-e2b-it-4bit"

    public let id: String
    public let capabilities: ModelCapabilities
    public let source: MLXModelSource
    public let predictedPeakMemoryBytes: UInt64?

    public convenience init(
        variant: GemmaVariant,
        capabilities: ModelCapabilities? = nil
    ) {
        self.init(
            source: variant.asModelSource,
            capabilities: capabilities ?? ModelCapabilities(
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsVision: false,
                supportsJSONSchema: false,
                maxContextTokens: variant.maxContextTokens,
                isOnDevice: true
            ),
            predictedPeakMemoryBytes: UInt64(max(0, variant.estimatedMemoryMB)) * 1_048_576
        )
    }

    public convenience init(
        model: String = MLXLocalProvider.defaultModelID,
        revision: String = "main",
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String>? = nil
    ) {
        self.init(
            source: .huggingFace(id: model, revision: revision),
            capabilities: capabilities,
            predictedPeakMemoryBytes: model == MLXLocalProvider.defaultModelID
                ? UInt64(GemmaModelCatalog.gemma4_e2b_4bit.estimatedMemoryMB) * 1_048_576
                : nil
        )
    }

    public convenience init(
        localModelDirectory: URL,
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String> = [],
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.init(
            source: .localDirectory(localModelDirectory),
            capabilities: capabilities,
            predictedPeakMemoryBytes: predictedPeakMemoryBytes
        )
    }

    public init(
        source: MLXModelSource,
        capabilities: ModelCapabilities = .mlxLocal,
        extraEOSTokens: Set<String> = [],
        predictedPeakMemoryBytes: UInt64? = nil
    ) {
        self.source = source
        self.capabilities = capabilities
        self.id = "mlx.\(source.identifier)"
        self.predictedPeakMemoryBytes = predictedPeakMemoryBytes
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        throw MLXLocalProviderError.unavailableOnPlatform
    }

    public func prepare() async throws {
        throw MLXLocalProviderError.unavailableOnPlatform
    }

    public func unload() async {}

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MLXLocalProviderError.unavailableOnPlatform)
        }
    }
}

#endif

#if canImport(MLXHuggingFace) && canImport(MLXLLM) && canImport(MLXLMCommon)
private actor MLXModelRuntime {
    private let source: MLXModelSource
    private let configuration: MLXLMCommon.ModelConfiguration
    private var cachedModel: MLXLMCommon.ModelContainer?
    private var loadingTask: Task<MLXLMCommon.ModelContainer, Error>?

    init(source: MLXModelSource, configuration: MLXLMCommon.ModelConfiguration) {
        self.source = source
        self.configuration = configuration
    }

    func modelContainer() async throws -> MLXLMCommon.ModelContainer {
        if let cachedModel {
            return cachedModel
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task { [source, configuration] in
            switch source {
            case .huggingFace:
                try ZeroCloudMode.ensureAllowed(provider: "MLX Hugging Face model download")
                return try await #huggingFaceLoadModelContainer(configuration: configuration)
            case .localDirectory(let directory):
                return try await LLMModelFactory.shared.loadContainer(
                    from: directory,
                    using: #huggingFaceTokenizerLoader()
                )
            }
        }

        loadingTask = task
        do {
            let model = try await task.value
            cachedModel = model
            loadingTask = nil
            return model
        } catch {
            loadingTask = nil
            throw error
        }
    }

    func unload() {
        loadingTask?.cancel()
        loadingTask = nil
        cachedModel = nil
    }
}
#endif

/// A concrete `ModelRuntimeAdapter` for installed Archon MLX packages.
///
/// The adapter deliberately accepts only manifests that declare both the MLX
/// runtime and MLX artifact format. It does not reinterpret GGUF, SafeTensors,
/// or other raw weights as MLX models.
public actor MLXModelRuntimeAdapter: ModelRuntimeAdapter {
    private var providers: [String: MLXLocalProvider] = [:]

    public init() {}

    public func load(model: InstalledModel) async throws {
        guard model.manifest.runtime == .mlx, model.manifest.format == .mlx else {
            throw ArchonModelsError.unsupportedArtifact("Only installed MLX artifacts can be loaded by MLXModelRuntimeAdapter.")
        }

        let predictedPeakMemoryBytes = ModelCompatibilityAnalyzer.estimatedPeakMemoryBytes(
            for: mlxModelVariant(from: model)
        )
        let provider = providers[model.id] ?? MLXLocalProvider(
            localModelDirectory: model.artifactURL,
            predictedPeakMemoryBytes: predictedPeakMemoryBytes
        )
        try await provider.prepare()
        providers[model.id] = provider
    }

    public func unload(model: InstalledModel) async {
        guard let provider = providers.removeValue(forKey: model.id) else { return }
        await provider.unload()
    }

    /// Returns the loaded provider for generation after `ModelLoadManager.load` succeeds.
    public func provider(for modelID: String) -> MLXLocalProvider? {
        providers[modelID]
    }
}

private func mlxModelVariant(from model: InstalledModel) -> ModelVariant {
    ModelVariant(
        id: model.id,
        name: model.manifest.modelName,
        modelID: model.manifest.modelID,
        source: .localImport,
        format: model.manifest.format,
        runtime: model.manifest.runtime,
        architecture: model.manifest.architecture,
        supportedDeviceArchitectures: model.manifest.supportedDeviceArchitectures,
        supportedPlatforms: model.manifest.platforms,
        minimumOS: model.manifest.minimumOS,
        parameterCount: model.manifest.parameterCount,
        contextLength: model.manifest.contextLength,
        precision: model.manifest.precision,
        quantization: model.manifest.quantization,
        kvCacheBytesPerToken: model.manifest.kvCacheBytesPerToken,
        sizeBytes: model.manifest.modelSizeBytes,
        estimatedMemoryBytes: model.manifest.estimatedMemoryBytes,
        estimatedQualityScore: model.manifest.estimatedQualityScore,
        estimatedTokensPerSecond: model.manifest.estimatedTokensPerSecond,
        sha256: model.manifest.checksum,
        resources: model.manifest.modelResources,
        tokenizerResources: model.manifest.tokenizerResources,
        capabilities: model.manifest.capabilities,
        isExperimental: model.manifest.isExperimental
    )
}

#if canImport(MLXHuggingFace) && canImport(MLXLLM) && canImport(MLXLMCommon)
private extension MLXLocalProvider {
    struct Request {
        let history: [MLXLMCommon.Chat.Message]
        let lastMessage: MLXLMCommon.Chat.Message
    }

    static func makeRequest(prompt: [ChatMessage]) throws -> Request {
        guard let last = prompt.last else {
            throw MLXLocalProviderError.emptyPrompt
        }

        let history = prompt.dropLast().map { message in
            MLXLMCommon.Chat.Message(
                role: mlxRole(for: message.role),
                content: message.content
            )
        }
        let lastMessage = MLXLMCommon.Chat.Message(
            role: mlxRole(for: last.role),
            content: last.content
        )
        return Request(history: history, lastMessage: lastMessage)
    }

    static func mlxRole(for role: MessageRole) -> MLXLMCommon.Chat.Message.Role {
        switch role {
        case .system, .developer:
            return .system
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool:
            return .tool
        }
    }

    static func generateParameters(from options: GenerationOptions) -> GenerateParameters {
        let rawTemperature = options.temperature ?? 0.6
        let temperature = rawTemperature.isFinite ? max(0, rawTemperature) : 0.6
        let rawTopP = options.topP ?? 1.0
        let topP = rawTopP.isFinite ? min(1.0, max(0.0, rawTopP)) : 1.0

        return GenerateParameters(
            maxTokens: options.maxTokens,
            temperature: Float(temperature),
            topP: Float(topP)
        )
    }

    static func toolSpecifications(from tools: [ToolDefinition]) -> [MLXLMCommon.ToolSpec]? {
        guard !tools.isEmpty else { return nil }

        return tools.map { definition in
            let parameters = definition.parametersJSONSchema.mapValues {
                mlxSendableValue($0.value)
            }
            return [
                "type": "function",
                "function": [
                    "name": definition.name,
                    "description": definition.description,
                    "parameters": parameters
                ] as [String: any Sendable]
            ] as MLXLMCommon.ToolSpec
        }
    }

    static func mlxSendableValue(_ value: Any) -> any Sendable {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value }
        if let value = value as? Double { return value }
        if let value = value as? Float { return value }
        if let value = value as? String { return value }
        if let value = value as? [AnySendable] {
            return value.map { mlxSendableValue($0.value) }
        }
        if let value = value as? [String: AnySendable] {
            return value.mapValues { mlxSendableValue($0.value) }
        }
        if let value = value as? [Any] {
            return value.map { mlxSendableValue($0) }
        }
        if let value = value as? [String: Any] {
            return value.mapValues { mlxSendableValue($0) }
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return String(describing: value)
    }

    static func archonToolCall(from call: MLXLMCommon.ToolCall) -> ToolCall {
        let argumentsData = try? JSONEncoder().encode(call.function.arguments)
        let arguments = argumentsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCall(name: call.function.name, arguments: arguments)
    }

    static func applyingStopSequences(to text: String, options: GenerationOptions) -> String {
        guard let range = options.stopSequences
            .compactMap({ text.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return text
        }
        return String(text[..<range.lowerBound])
    }
}
#endif
