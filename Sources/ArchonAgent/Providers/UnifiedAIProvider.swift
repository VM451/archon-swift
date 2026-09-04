import Foundation

/// Unified enumeration of all AI model runtime targets supported across the Apple ecosystem and Cloud APIs.
public enum ArchonAIModel: Sendable {
    // MARK: - Apple Platform Native Models

    /// Apple Foundation Model (on-device Apple Intelligence, SystemLanguageModel).
    case appleFoundationModel(id: String = "apple.foundation.default")

    /// Apple Private Cloud Compute (PCC) server model with end-to-end cryptographic privacy verification.
    case privateCloudCompute(id: String = "apple.pcc.default")

    /// Apple Core AI framework runtime on Apple Silicon (Neural Engine & GPU specialization).
    case coreAI(variant: GemmaVariant = GemmaModelCatalog.defaultVariant)

    /// Apple Core AI with explicit source (bundled asset or model identifier).
    case coreAISource(CoreAIModelSource)

    /// Apple MLX Swift Metal runtime with Hugging Face open weights.
    case mlx(variant: GemmaVariant = GemmaModelCatalog.defaultVariant)

    /// Apple MLX with explicit model source.
    case mlxSource(MLXModelSource)

    // MARK: - Zero-Config Hardware Adaptive

    /// Hardware-adaptive on-device routing (Apple Foundation Model on supported hardware, auto-sized Gemma 4 on older devices).
    case adaptive(
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto
    )

    // MARK: - Industry Leading Cloud Providers

    /// Google Gemini (Gemini 2.5 Flash, Gemini 2.5 Pro).
    case gemini(apiKey: String, model: String = "gemini-2.5-flash")

    /// Anthropic Claude (Claude 3.7 Sonnet, Claude 3.5 Haiku).
    case claude(apiKey: String, model: String = "claude-3-7-sonnet-20250219")

    /// OpenAI (GPT-4o, GPT-4o-mini, o3-mini).
    case openAI(apiKey: String, model: String = "gpt-4o")

    /// Local Ollama inference server.
    case ollama(endpoint: URL = URL(string: "http://localhost:11434")!, model: String = "gemma4:latest")

    /// Custom user-provided LLM provider.
    case custom(any LLMProvider)
}

/// Unified factory and orchestrator for creating AI model providers across Apple on-device,
/// Private Cloud Compute, Core AI, MLX, and cloud LLMs.
public enum ArchonAI: Sendable {
    /// Resolves an `any LLMProvider` conforming to the specified model target.
    public static func model(_ target: ArchonAIModel) -> any LLMProvider {
        switch target {
        case .appleFoundationModel(let id):
            return AppleFoundationModelProvider(id: id)

        case .privateCloudCompute(let id):
            return PrivateCloudComputeProvider(id: id)

        case .coreAI(let variant):
            return CoreAIProvider(variant: variant)

        case .coreAISource(let source):
            return CoreAIProvider(source: source)

        case .mlx(let variant):
            return MLXLocalProvider(variant: variant)

        case .mlxSource(let source):
            return MLXLocalProvider(source: source)

        case .adaptive(let preference, let runtime):
            return OnDeviceProvider(strategy: .adaptive(preference: preference, runtime: runtime))

        case .gemini(let apiKey, let model):
            return GoogleGeminiProvider(apiKey: apiKey, model: model)

        case .claude(let apiKey, let model):
            return AnthropicProvider(apiKey: apiKey, model: model)

        case .openAI(let apiKey, let model):
            return OpenAIProvider(apiKey: apiKey, model: model)

        case .ollama(let endpoint, let model):
            return OllamaProvider(model: model, endpoint: endpoint)

        case .custom(let provider):
            return provider
        }
    }

    // MARK: - Ergonomic Static Factory Shortcuts

    /// Zero-configuration adaptive on-device provider:
    /// - iPhone 15 Pro+, iPhone 16 series, M-series Macs & iPads -> Apple Foundation Model
    /// - Older devices (iPhone 11-14, iPhone 15 base) -> Auto-sized Google Gemma 4 with 50% headroom guarantee
    public static var auto: any LLMProvider {
        OnDeviceProvider.default
    }

    /// Apple Foundation Model on-device runtime.
    public static var appleFoundation: any LLMProvider {
        AppleFoundationModelProvider.default
    }

    /// Apple Private Cloud Compute server runtime.
    public static var privateCloudCompute: any LLMProvider {
        PrivateCloudComputeProvider.default
    }

    /// Apple Core AI runtime on Apple Silicon (Neural Engine & GPU) with Gemma 4.
    public static func coreAI(
        variant: GemmaVariant = GemmaModelCatalog.defaultVariant,
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst
    ) -> any LLMProvider {
        CoreAIProvider(variant: variant, computeUnit: computeUnit)
    }

    /// Apple MLX Swift Metal runtime with Gemma 4.
    public static func mlx(
        variant: GemmaVariant = GemmaModelCatalog.defaultVariant
    ) -> any LLMProvider {
        MLXLocalProvider(variant: variant)
    }

    /// Google Gemini 2.5 provider.
    public static func gemini(
        apiKey: String,
        model: String = "gemini-2.5-flash"
    ) -> any LLMProvider {
        GoogleGeminiProvider(apiKey: apiKey, model: model)
    }

    /// Anthropic Claude 3.7 Sonnet provider.
    public static func claude(
        apiKey: String,
        model: String = "claude-3-7-sonnet-20250219"
    ) -> any LLMProvider {
        AnthropicProvider(apiKey: apiKey, model: model)
    }

    /// OpenAI GPT-4o provider.
    public static func openAI(
        apiKey: String,
        model: String = "gpt-4o"
    ) -> any LLMProvider {
        OpenAIProvider(apiKey: apiKey, model: model)
    }

}
