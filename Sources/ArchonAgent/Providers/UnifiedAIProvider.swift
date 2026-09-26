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

    /// Hardware-adaptive on-device routing using the bundled or supplied adaptive catalog.
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

    /// Mistral AI (Medium 3.5, Large 3, Small 4) over the OpenAI-compatible
    /// `https://api.mistral.ai/v1` endpoint.
    case mistral(apiKey: String, model: String = "mistral-medium-3-5")

    /// OpenRouter (Nemotron 3.5 Lightning, Nemotron 3 Ultra) over the
    /// OpenAI-compatible `https://openrouter.ai/api/v1` endpoint.
    case openrouter(apiKey: String, model: String = "nvidia/nemotron-3.5-lightning:free")

    // MARK: - Cloud Inference Providers (OpenAI-compatible, API key)

    /// Cerebras Cloud over `https://api.cerebras.ai/v1`.
    case cerebras(apiKey: String, model: String = "llama-3.3-70b")

    /// SambaNova Cloud over `https://api.sambanova.ai/v1`.
    case sambaNova(apiKey: String, model: String = "Meta-Llama-3.3-70B-Instruct")

    /// Groq inference cloud over `https://api.groq.com/openai/v1`.
    case groq(apiKey: String, model: String = "llama-3.3-70b-versatile")

    /// Azure OpenAI over a deployment-scoped resource URL with the `api-key`
    /// header. Entra ID is not supported.
    case azure(
        apiKey: String,
        resource: String,
        deployment: String,
        model: String? = nil,
        apiVersion: String = "2025-04-01-preview"
    )

    /// DeepInfra Turbo tier over `https://api.deepinfra.com/v1/openai`.
    case deepInfraTurbo(apiKey: String, model: String = DeepInfraProvider.turboDefaultModel)

    /// Crusoe Cloud inference over `https://api.intelligence.crusoecloud.com/v1`.
    case crusoe(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct")

    /// Nebius AI Studio over `https://api.studio.nebius.com/v1`.
    case nebius(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct")

    /// Baseten shared Model APIs over `https://inference.baseten.co/v1`.
    case baseten(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct")

    /// Google Vertex AI in Express mode (API key, `x-goog-api-key`).
    case vertex(apiKey: String, model: String = "gemini-2.5-flash")

    /// Parasail serverless inference over `https://api.saas.parasail.io/v1`.
    case parasail(apiKey: String, model: String = "DeepSeek-R1")

    /// Amazon Bedrock over the OpenAI-compatible regional runtime route with
    /// a Bedrock API key. SigV4/Converse is not included.
    case bedrock(apiKey: String, model: String = "anthropic.claude-sonnet-4-6", region: String = "us-east-1")

    /// Together AI serverless inference over `https://api.together.xyz/v1`.
    case together(apiKey: String, model: String = "meta-llama/Llama-3.3-70B-Instruct-Turbo")

    /// Scaleway Generative APIs over `https://api.scaleway.ai/v1`.
    case scaleway(apiKey: String, model: String = "mistral-small-3.2-24b-instruct-2506")

    /// Novita AI over `https://api.novita.ai/v3/openai`.
    case novita(apiKey: String, model: String = "meta-llama/llama-3.1-8b-instruct")

    /// DeepInfra base tier over `https://api.deepinfra.com/v1/openai`.
    case deepInfra(apiKey: String, model: String = DeepInfraProvider.baseDefaultModel)

    /// CoreWeave inference over a host-supplied deployment URL.
    case coreWeave(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct", endpoint: URL)

    /// Cloudflare Workers AI over the account-scoped OpenAI-compatible route.
    case cloudflare(apiKey: String, accountID: String, model: String = "@cf/meta/llama-3.1-8b-instruct")

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

        case .mistral(let apiKey, let model):
            return MistralProvider(apiKey: apiKey, model: model)

        case .openrouter(let apiKey, let model):
            return OpenRouterProvider(apiKey: apiKey, model: model)

        case .cerebras(let apiKey, let model):
            return CerebrasProvider(apiKey: apiKey, model: model)

        case .sambaNova(let apiKey, let model):
            return SambaNovaProvider(apiKey: apiKey, model: model)

        case .groq(let apiKey, let model):
            return GroqProvider(apiKey: apiKey, model: model)

        case .azure(let apiKey, let resource, let deployment, let model, let apiVersion):
            return AzureOpenAIProvider(
                apiKey: apiKey,
                resource: resource,
                deployment: deployment,
                model: model,
                apiVersion: apiVersion
            )

        case .deepInfraTurbo(let apiKey, let model):
            return DeepInfraProvider(apiKey: apiKey, model: model)

        case .crusoe(let apiKey, let model):
            return CrusoeProvider(apiKey: apiKey, model: model)

        case .nebius(let apiKey, let model):
            return NebiusProvider(apiKey: apiKey, model: model)

        case .baseten(let apiKey, let model):
            return BasetenProvider(apiKey: apiKey, model: model)

        case .vertex(let apiKey, let model):
            return GoogleVertexProvider(apiKey: apiKey, model: model)

        case .parasail(let apiKey, let model):
            return ParasailProvider(apiKey: apiKey, model: model)

        case .bedrock(let apiKey, let model, let region):
            return BedrockProvider(apiKey: apiKey, model: model, region: region)

        case .together(let apiKey, let model):
            return TogetherProvider(apiKey: apiKey, model: model)

        case .scaleway(let apiKey, let model):
            return ScalewayProvider(apiKey: apiKey, model: model)

        case .novita(let apiKey, let model):
            return NovitaProvider(apiKey: apiKey, model: model)

        case .deepInfra(let apiKey, let model):
            return DeepInfraProvider(apiKey: apiKey, model: model)

        case .coreWeave(let apiKey, let model, let endpoint):
            return CoreWeaveProvider(apiKey: apiKey, model: model, endpoint: endpoint)

        case .cloudflare(let apiKey, let accountID, let model):
            return CloudflareProvider(apiKey: apiKey, accountID: accountID, model: model)

        case .ollama(let endpoint, let model):
            return OllamaProvider(model: model, endpoint: endpoint)

        case .custom(let provider):
            return provider
        }
    }

    // MARK: - Ergonomic Static Factory Shortcuts

    /// Zero-configuration adaptive on-device provider:
    /// - iPhone 15 Pro+, iPhone 16 series, M-series Macs & iPads -> Apple Foundation Model
    /// - Other devices -> the best eligible entry in the bundled adaptive catalog
    public static var auto: any LLMProvider {
        OnDeviceProvider.default
    }

    /// Creates a hardware-adaptive provider from an application- or registry-
    /// supplied catalog. This is the update path for new model releases: the
    /// app can refresh descriptors without requiring a new provider family.
    public static func adaptive(
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto,
        catalog: AdaptiveModelCatalog,
        hardwareProfile: DeviceHardwareProfile = .current
    ) -> any LLMProvider {
        OnDeviceProvider.adaptive(
            preference: preference,
            runtime: runtime,
            catalog: catalog,
            hardwareProfile: hardwareProfile
        )
    }

    /// Apple Foundation Model on-device runtime.
    public static var appleFoundation: any LLMProvider {
        AppleFoundationModelProvider.default
    }

    /// Apple Private Cloud Compute server runtime.
    public static var privateCloudCompute: any LLMProvider {
        PrivateCloudComputeProvider.default
    }

    /// Apple Core AI runtime on Apple Silicon (Neural Engine & GPU), using the
    /// Gemma compatibility convenience overload.
    public static func coreAI(
        variant: GemmaVariant = GemmaModelCatalog.defaultVariant,
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst
    ) -> any LLMProvider {
        CoreAIProvider(variant: variant, computeUnit: computeUnit)
    }

    /// Apple MLX Swift Metal runtime, using the Gemma compatibility convenience
    /// overload.
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

    /// Mistral AI provider (Medium 3.5 default; Large 3 and Small 4 via `model`).
    public static func mistral(
        apiKey: String,
        model: String = "mistral-medium-3-5"
    ) -> any LLMProvider {
        MistralProvider(apiKey: apiKey, model: model)
    }

    /// OpenRouter provider (Nemotron 3.5 Lightning default; 3 Ultra via `model`).
    public static func openrouter(
        apiKey: String,
        model: String = "nvidia/nemotron-3.5-lightning:free"
    ) -> any LLMProvider {
        OpenRouterProvider(apiKey: apiKey, model: model)
    }

    /// Cerebras Cloud provider.
    public static func cerebras(apiKey: String, model: String = "llama-3.3-70b") -> any LLMProvider {
        CerebrasProvider(apiKey: apiKey, model: model)
    }

    /// SambaNova Cloud provider.
    public static func sambaNova(apiKey: String, model: String = "Meta-Llama-3.3-70B-Instruct") -> any LLMProvider {
        SambaNovaProvider(apiKey: apiKey, model: model)
    }

    /// Groq inference provider.
    public static func groq(apiKey: String, model: String = "llama-3.3-70b-versatile") -> any LLMProvider {
        GroqProvider(apiKey: apiKey, model: model)
    }

    /// Azure OpenAI provider over a deployment-scoped resource URL.
    public static func azure(
        apiKey: String,
        resource: String,
        deployment: String,
        model: String? = nil,
        apiVersion: String = "2025-04-01-preview"
    ) -> any LLMProvider {
        AzureOpenAIProvider(apiKey: apiKey, resource: resource, deployment: deployment, model: model, apiVersion: apiVersion)
    }

    /// DeepInfra provider (Turbo default; base tier via `model`).
    public static func deepInfra(apiKey: String, model: String = DeepInfraProvider.turboDefaultModel) -> any LLMProvider {
        DeepInfraProvider(apiKey: apiKey, model: model)
    }

    /// Crusoe Cloud inference provider.
    public static func crusoe(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct") -> any LLMProvider {
        CrusoeProvider(apiKey: apiKey, model: model)
    }

    /// Nebius AI Studio provider.
    public static func nebius(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct") -> any LLMProvider {
        NebiusProvider(apiKey: apiKey, model: model)
    }

    /// Baseten shared Model APIs provider.
    public static func baseten(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct") -> any LLMProvider {
        BasetenProvider(apiKey: apiKey, model: model)
    }

    /// Google Vertex AI (Express mode) provider.
    public static func vertex(apiKey: String, model: String = "gemini-2.5-flash") -> any LLMProvider {
        GoogleVertexProvider(apiKey: apiKey, model: model)
    }

    /// Parasail serverless inference provider.
    public static func parasail(apiKey: String, model: String = "DeepSeek-R1") -> any LLMProvider {
        ParasailProvider(apiKey: apiKey, model: model)
    }

    /// Amazon Bedrock provider over the OpenAI-compatible regional route.
    public static func bedrock(
        apiKey: String,
        model: String = "anthropic.claude-sonnet-4-6",
        region: String = "us-east-1"
    ) -> any LLMProvider {
        BedrockProvider(apiKey: apiKey, model: model, region: region)
    }

    /// Together AI provider.
    public static func together(apiKey: String, model: String = "meta-llama/Llama-3.3-70B-Instruct-Turbo") -> any LLMProvider {
        TogetherProvider(apiKey: apiKey, model: model)
    }

    /// Scaleway Generative APIs provider.
    public static func scaleway(apiKey: String, model: String = "mistral-small-3.2-24b-instruct-2506") -> any LLMProvider {
        ScalewayProvider(apiKey: apiKey, model: model)
    }

    /// Novita AI provider.
    public static func novita(apiKey: String, model: String = "meta-llama/llama-3.1-8b-instruct") -> any LLMProvider {
        NovitaProvider(apiKey: apiKey, model: model)
    }

    /// CoreWeave inference provider over a host-supplied deployment URL.
    public static func coreWeave(
        apiKey: String,
        model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct",
        endpoint: URL
    ) -> any LLMProvider {
        CoreWeaveProvider(apiKey: apiKey, model: model, endpoint: endpoint)
    }

    /// Cloudflare Workers AI provider.
    public static func cloudflare(
        apiKey: String,
        accountID: String,
        model: String = "@cf/meta/llama-3.1-8b-instruct"
    ) -> any LLMProvider {
        CloudflareProvider(apiKey: apiKey, accountID: accountID, model: model)
    }
}
