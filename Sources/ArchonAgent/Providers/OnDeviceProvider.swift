import Foundation

/// The local inference backend selected by `OnDeviceProvider`.
public enum OnDeviceBackend: String, Codable, Equatable, Sendable {
    /// Apple's built-in SystemLanguageModel.
    case appleFoundationModel

    /// Apple's native Core AI framework running custom neural models on Neural Engine & GPU.
    case coreAI

    /// MLX Swift runtime executing open-source weights over Metal.
    case mlx

    /// No local candidate satisfied the adaptive catalog requirements.
    case unavailable
}

/// Runtime preference when multiple on-device engines are available.
public enum OnDeviceRuntimePreference: String, Codable, Equatable, Sendable {
    /// Automatically prefers Apple Foundation Model on eligible devices and otherwise uses MLX for curated open-weight variants.
    /// Core AI requires an explicit Core AI model source or runtime preference because a Hugging Face model ID is not proof of a compatible export.
    case auto

    /// Prefers Apple's native Core AI runtime for custom models on the Neural Engine.
    case preferCoreAI

    /// Prefers MLX Swift Metal runtime for dynamic Hugging Face models.
    case preferMLX

    /// Restricts execution strictly to Apple's built-in SystemLanguageModel.
    case appleFoundationModelOnly
}

/// Strategy for routing and sizing local on-device models across Apple Foundation Models, Core AI, and MLX.
public enum OnDeviceStrategy: Sendable, Equatable {
    /// Automatically probes hardware (RAM tier, cores, Apple Intelligence support) and selects
    /// the best eligible candidate from an `AdaptiveModelCatalog`.
    case adaptive(
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto
    )

    /// Requests a specific curated Gemma variant through the preferred
    /// on-device runtime. The request is rejected if the predicted peak does
    /// not fit the current device envelope.
    case gemma(
        GemmaVariant,
        runtime: OnDeviceRuntimePreference = .auto
    )

    /// Explicitly loads a model using Apple's native Core AI framework.
    case coreAI(CoreAIModelSource)

    /// Uses an explicit MLX source (Hugging Face ID or local file directory).
    case explicitMLXSource(MLXModelSource)
}

/// Hardware-aware on-device provider orchestration across Apple Foundation Models, Core AI, and MLX.
///
/// For Apple Intelligence eligible hardware (iPhone 15 Pro, iPhone 15 Pro Max,
/// iPhone 16 series, M-series Macs & iPads), Apple Foundation Models are preferred
/// as the primary local AI engine.
///
/// For custom neural models (such as Gemma, Qwen, Mistral, Llama, or a future
/// catalog family) this provider resolves a compatible entry from an
/// `AdaptiveModelCatalog`, then delegates to Apple's **Core AI** framework or
/// **MLX Swift**. The selector uses declared runtime, memory, context, device,
/// quality, speed, energy, thermal, download, and license metadata; it does
/// not infer runtime compatibility from a model name.
public final class OnDeviceProvider: LLMProvider, @unchecked Sendable {
    public static let `default` = OnDeviceProvider()

    public let id: String
    public let capabilities: ModelCapabilities
    public let backend: OnDeviceBackend
    public let hardwareProfile: DeviceHardwareProfile
    /// The generic catalog entry selected for local execution, when one was selected.
    public let selectedModel: AdaptiveModelCandidate?
    /// Deprecated compatibility view for callers that still use the Gemma-only API.
    public let selectedGemmaVariant: GemmaVariant?

    private let selectedProvider: any LLMProvider

    /// Creates a default adaptive on-device provider.
    public convenience init() {
        self.init(
            strategy: .adaptive(preference: .adaptive, runtime: .auto),
            hardwareProfile: .current,
            appleFoundationModelAvailable: nil,
            catalog: .builtIn
        )
    }

    /// Creates an adaptive on-device provider with an explicit Apple Foundation Model availability override.
    public convenience init(appleFoundationModelAvailable: Bool?) {
        self.init(
            strategy: .adaptive(preference: .adaptive, runtime: .auto),
            hardwareProfile: .current,
            appleFoundationModelAvailable: appleFoundationModelAvailable,
            catalog: .builtIn
        )
    }

    /// Creates an adaptive on-device provider based on the specified strategy and device profile.
    ///
    /// - Parameters:
    ///   - strategy: The on-device selection and optimization strategy.
    ///   - hardwareProfile: The device hardware profile (defaults to `.current`).
    ///   - appleFoundationModelAvailable: Optional override for deterministic test verification.
    ///   - catalog: Curated local candidates. The default is the bundled seed;
    ///     consuming apps can replace it with refreshed model descriptors.
    public init(
        strategy: OnDeviceStrategy = .adaptive(preference: .adaptive, runtime: .auto),
        hardwareProfile: DeviceHardwareProfile = .current,
        appleFoundationModelAvailable: Bool? = nil,
        catalog: AdaptiveModelCatalog = .builtIn
    ) {
        self.hardwareProfile = hardwareProfile

        let (provider, selectedBackend, variant) = Self.resolveProvider(
            for: strategy,
            hardwareProfile: hardwareProfile,
            appleFoundationModelAvailable: appleFoundationModelAvailable,
            catalog: catalog
        )

        self.backend = selectedBackend
        self.selectedModel = variant.candidate
        self.selectedGemmaVariant = variant.gemmaVariant
        self.selectedProvider = provider
        self.id = provider.id
        self.capabilities = provider.capabilities
    }

    /// Creates an automatic provider with an explicit MLX model identifier.
    public convenience init(
        mlxModel: String,
        mlxRevision: String = "main",
        appleFoundationModelAvailable: Bool? = nil
    ) {
        self.init(
            strategy: .explicitMLXSource(.huggingFace(id: mlxModel, revision: mlxRevision)),
            hardwareProfile: .current,
            appleFoundationModelAvailable: appleFoundationModelAvailable
        )
    }

    /// Creates an automatic provider with an explicit MLX source (Hugging Face or local directory).
    public convenience init(
        mlxSource: MLXModelSource,
        appleFoundationModelAvailable: Bool? = nil
    ) {
        self.init(
            strategy: .explicitMLXSource(mlxSource),
            hardwareProfile: .current,
            appleFoundationModelAvailable: appleFoundationModelAvailable
        )
    }

    /// Creates an automatic provider with an explicit Core AI model source.
    public convenience init(
        coreAISource: CoreAIModelSource,
        appleFoundationModelAvailable: Bool? = nil
    ) {
        self.init(
            strategy: .coreAI(coreAISource),
            hardwareProfile: .current,
            appleFoundationModelAvailable: appleFoundationModelAvailable
        )
    }

    // MARK: - Ergonomic Static Factory Methods

    /// Creates an adaptive on-device provider balancing speed, intelligence, and RAM.
    public static func adaptive(
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto,
        catalog: AdaptiveModelCatalog = .builtIn,
        hardwareProfile: DeviceHardwareProfile = .current
    ) -> OnDeviceProvider {
        OnDeviceProvider(
            strategy: .adaptive(preference: preference, runtime: runtime),
            hardwareProfile: hardwareProfile,
            catalog: catalog
        )
    }

    /// Creates an on-device provider optimized for speed-first and low memory.
    public static func speedFirst() -> OnDeviceProvider {
        OnDeviceProvider(strategy: .adaptive(preference: .speedFirst, runtime: .auto))
    }

    /// Creates an on-device provider optimized for maximum reasoning intelligence within hardware limits.
    public static func intelligenceFirst() -> OnDeviceProvider {
        OnDeviceProvider(strategy: .adaptive(preference: .intelligenceFirst, runtime: .auto))
    }

    /// Creates an on-device provider explicitly using a curated Gemma variant.
    public static func gemma(
        _ variant: GemmaVariant,
        runtime: OnDeviceRuntimePreference = .auto
    ) -> OnDeviceProvider {
        OnDeviceProvider(strategy: .gemma(variant, runtime: runtime))
    }

    /// Creates an on-device provider explicitly routing through Apple's Core AI framework.
    public static func coreAI(
        model: String = "gemma-4-e2b.coreai"
    ) -> OnDeviceProvider {
        OnDeviceProvider(strategy: .coreAI(.modelIdentifier(model)))
    }

    /// Creates an on-device provider with a compiled Core AI asset source.
    public static func coreAI(
        source: CoreAIModelSource
    ) -> OnDeviceProvider {
        OnDeviceProvider(strategy: .coreAI(source))
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try await selectedProvider.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        selectedProvider.stream(prompt: prompt, tools: tools, options: options)
    }

    // MARK: - Private Sizing & Resolution Helper

    private static func resolveProvider(
        for strategy: OnDeviceStrategy,
        hardwareProfile: DeviceHardwareProfile,
        appleFoundationModelAvailable: Bool?,
        catalog: AdaptiveModelCatalog
    ) -> (
        provider: any LLMProvider,
        backend: OnDeviceBackend,
        variant: (candidate: AdaptiveModelCandidate?, gemmaVariant: GemmaVariant?)
    ) {
        let isAppleModelEligible = appleFoundationModelAvailable
            ?? hardwareProfile.isAppleFoundationModelSupported

        switch strategy {
        case .adaptive(let preference, let runtimePref):
            if isAppleModelEligible && runtimePref != .preferCoreAI && runtimePref != .preferMLX {
                return (
                    AppleFoundationModelProvider.default,
                    .appleFoundationModel,
                    (candidate: nil, gemmaVariant: nil)
                )
            }

            guard let candidate = catalog.resolve(
                for: hardwareProfile,
                preference: preference,
                runtime: runtimePref
            ) else {
                return (
                    UnavailableAdaptiveModelProvider(),
                    .unavailable,
                    (candidate: nil, gemmaVariant: nil)
                )
            }
            return Self.provider(for: candidate)

        case .gemma(let variant, let runtimePref):
            guard GemmaModelCatalog.fits(variant, on: hardwareProfile) else {
                return (
                    UnavailableAdaptiveModelProvider(),
                    .unavailable,
                    (candidate: nil, gemmaVariant: nil)
                )
            }
            guard runtimePref != .appleFoundationModelOnly else {
                return (
                    UnavailableAdaptiveModelProvider(),
                    .unavailable,
                    (candidate: nil, gemmaVariant: nil)
                )
            }
            if runtimePref == .preferCoreAI, !hardwareProfile.isCoreAISupported {
                return (
                    UnavailableAdaptiveModelProvider(),
                    .unavailable,
                    (candidate: nil, gemmaVariant: nil)
                )
            }
            let candidate = AdaptiveModelCatalog.builtIn.candidates.first {
                $0.id == "\(variant.huggingFaceID)#\(runtimePref == .preferCoreAI ? "coreAI" : "mlx")"
            } ?? AdaptiveModelCandidate(
                id: "\(variant.huggingFaceID)#mlx",
                name: variant.name,
                family: "Gemma",
                source: .mlx(
                    source: variant.asModelSource,
                    extraEOSTokens: Set(variant.extraEOSTokens)
                ),
                capabilities: .mlxLocal,
                estimatedMemoryBytes: UInt64(variant.estimatedMemoryMB) * 1024 * 1024,
                maxContextTokens: variant.maxContextTokens,
                minimumSystemRAMGB: variant.minSystemRAMGB,
                legacyGemmaVariant: variant
            )
            let resolvedCandidate: AdaptiveModelCandidate
            switch runtimePref {
            case .preferCoreAI:
                resolvedCandidate = AdaptiveModelCandidate(
                    id: "\(variant.coreAIModelIdentifier)#coreAI",
                    name: variant.name,
                    family: "Gemma",
                    source: .coreAI(source: variant.asCoreAISource, computeUnit: .neuralEngineFirst),
                    capabilities: .coreAI,
                    estimatedMemoryBytes: candidate.estimatedMemoryBytes,
                    maxContextTokens: variant.maxContextTokens,
                    minimumSystemRAMGB: variant.minSystemRAMGB,
                    legacyGemmaVariant: variant
                )
            default:
                resolvedCandidate = candidate
            }
            let result = Self.provider(for: resolvedCandidate)
            return (
                result.provider,
                result.backend,
                (candidate: resolvedCandidate, gemmaVariant: variant)
            )

        case .coreAI(let source):
            return (
                CoreAIProvider(source: source),
                .coreAI,
                (candidate: nil, gemmaVariant: nil)
            )

        case .explicitMLXSource(let source):
            return (
                MLXLocalProvider(source: source),
                .mlx,
                (candidate: nil, gemmaVariant: nil)
            )
        }
    }

    private static func provider(
        for candidate: AdaptiveModelCandidate
    ) -> (
        provider: any LLMProvider,
        backend: OnDeviceBackend,
        variant: (candidate: AdaptiveModelCandidate?, gemmaVariant: GemmaVariant?)
    ) {
        switch candidate.source {
        case .mlx(let source, let extraEOSTokens):
            return (
                MLXLocalProvider(
                    source: source,
                    capabilities: candidate.capabilities,
                    extraEOSTokens: extraEOSTokens,
                    predictedPeakMemoryBytes: candidate.estimatedMemoryBytes
                ),
                .mlx,
                (candidate: candidate, gemmaVariant: candidate.legacyGemmaVariant)
            )
        case .coreAI(let source, let computeUnit):
            return (
                CoreAIProvider(
                    source: source,
                    computeUnit: computeUnit,
                    capabilities: candidate.capabilities,
                    predictedPeakMemoryBytes: candidate.estimatedMemoryBytes
                ),
                .coreAI,
                (candidate: candidate, gemmaVariant: candidate.legacyGemmaVariant)
            )
        }
    }
}
