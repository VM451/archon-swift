import Foundation

/// The local inference backend selected by `OnDeviceProvider`.
public enum OnDeviceBackend: String, Codable, Equatable, Sendable {
    /// Apple's built-in SystemLanguageModel.
    case appleFoundationModel

    /// Apple's native Core AI framework running custom neural models on Neural Engine & GPU.
    case coreAI

    /// MLX Swift runtime executing open-source weights over Metal.
    case mlx
}

/// Runtime preference when multiple on-device engines are available.
public enum OnDeviceRuntimePreference: String, Codable, Equatable, Sendable {
    /// Automatically prefers Apple Foundation Model on eligible devices, otherwise Core AI if available, falling back to MLX.
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
    /// Automatically probes hardware (RAM tier, cores, Apple Intelligence support) and balances
    /// speed, reasoning intelligence, and memory footprint.
    case adaptive(
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto
    )

    /// Forces a specific curated Gemma variant running through the preferred on-device runtime.
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
/// For custom neural models (such as Google Gemma 4/3/2, Qwen, Mistral, Llama) or
/// devices running on Apple Silicon, this provider seamlessly delegates to
/// Apple's **Core AI** framework or **MLX Swift**, adaptively sizing the model
/// variant (1B, 2B/E2B, 4B, 9B) to balance speed, intelligence, and RAM footprint.
public final class OnDeviceProvider: LLMProvider, @unchecked Sendable {
    public static let `default` = OnDeviceProvider()

    public let id: String
    public let capabilities: ModelCapabilities
    public let backend: OnDeviceBackend
    public let hardwareProfile: DeviceHardwareProfile
    public let selectedGemmaVariant: GemmaVariant?

    private let selectedProvider: any LLMProvider

    /// Creates a default adaptive on-device provider.
    public convenience init() {
        self.init(
            strategy: .adaptive(preference: .adaptive, runtime: .auto),
            hardwareProfile: .current,
            appleFoundationModelAvailable: nil
        )
    }

    /// Creates an adaptive on-device provider with an explicit Apple Foundation Model availability override.
    public convenience init(appleFoundationModelAvailable: Bool?) {
        self.init(
            strategy: .adaptive(preference: .adaptive, runtime: .auto),
            hardwareProfile: .current,
            appleFoundationModelAvailable: appleFoundationModelAvailable
        )
    }

    /// Creates an adaptive on-device provider based on the specified strategy and device profile.
    ///
    /// - Parameters:
    ///   - strategy: The on-device selection and optimization strategy.
    ///   - hardwareProfile: The device hardware profile (defaults to `.current`).
    ///   - appleFoundationModelAvailable: Optional override for deterministic test verification.
    public init(
        strategy: OnDeviceStrategy = .adaptive(preference: .adaptive, runtime: .auto),
        hardwareProfile: DeviceHardwareProfile = .current,
        appleFoundationModelAvailable: Bool? = nil
    ) {
        self.hardwareProfile = hardwareProfile

        let (provider, selectedBackend, variant) = Self.resolveProvider(
            for: strategy,
            hardwareProfile: hardwareProfile,
            appleFoundationModelAvailable: appleFoundationModelAvailable
        )

        self.backend = selectedBackend
        self.selectedGemmaVariant = variant
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
        runtime: OnDeviceRuntimePreference = .auto
    ) -> OnDeviceProvider {
        OnDeviceProvider(strategy: .adaptive(preference: preference, runtime: runtime))
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
        appleFoundationModelAvailable: Bool?
    ) -> (provider: any LLMProvider, backend: OnDeviceBackend, variant: GemmaVariant?) {
        let isAppleModelEligible = appleFoundationModelAvailable
            ?? hardwareProfile.isAppleFoundationModelSupported

        switch strategy {
        case .adaptive(let preference, let runtimePref):
            if isAppleModelEligible && runtimePref != .preferCoreAI && runtimePref != .preferMLX {
                return (AppleFoundationModelProvider.default, .appleFoundationModel, nil)
            }

            let variant = GemmaModelCatalog.resolve(
                for: hardwareProfile,
                preference: preference
            )

            if runtimePref == .preferCoreAI {
                return (CoreAIProvider(variant: variant), .coreAI, variant)
            } else {
                return (MLXLocalProvider(variant: variant), .mlx, variant)
            }

        case .gemma(let variant, let runtimePref):
            if runtimePref == .preferCoreAI {
                return (CoreAIProvider(variant: variant), .coreAI, variant)
            } else {
                return (MLXLocalProvider(variant: variant), .mlx, variant)
            }

        case .coreAI(let source):
            return (CoreAIProvider(source: source), .coreAI, nil)

        case .explicitMLXSource(let source):
            return (MLXLocalProvider(source: source), .mlx, nil)
        }
    }
}
