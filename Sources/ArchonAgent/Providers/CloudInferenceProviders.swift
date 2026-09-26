import Foundation

// MARK: - OpenAI-compatible cloud inference providers
//
// Thin adapters over the shared `OpenAIProvider` transport (one over the
// Gemini transport for Vertex). Each carries its vendor's chat-completions
// endpoint, auth style, and a reasonable default model; hosts override the
// model freely because vendor catalogs drift. API keys are host-supplied,
// never stored here, and every call honors `ZeroCloudMode`.

/// Cerebras Cloud over `https://api.cerebras.ai/v1` (Bearer).
public final class CerebrasProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Cerebras"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "llama-3.3-70b", urlSession: URLSession = .shared) {
        self.id = "cerebras.\(model)"
        self.endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// SambaNova Cloud over `https://api.sambanova.ai/v1` (Bearer).
public final class SambaNovaProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "SambaNova"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "Meta-Llama-3.3-70B-Instruct", urlSession: URLSession = .shared) {
        self.id = "sambanova.\(model)"
        self.endpoint = URL(string: "https://api.sambanova.ai/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Groq inference cloud over `https://api.groq.com/openai/v1` (Bearer).
/// This is the Groq inference provider, not xAI Grok (`GrokProvider`).
public final class GroqProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Groq"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "llama-3.3-70b-versatile", urlSession: URLSession = .shared) {
        self.id = "groq.\(model)"
        self.endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Azure OpenAI over deployment-scoped
/// `https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version=...`
/// with the Azure `api-key` header (not Bearer). Entra ID is not supported;
/// use an Azure resource API key.
public final class AzureOpenAIProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "AzureOpenAI"
    private let transport: OpenAIProvider

    public init(
        apiKey: String,
        resource: String,
        deployment: String,
        model: String? = nil,
        apiVersion: String = "2025-04-01-preview",
        urlSession: URLSession = .shared
    ) {
        let resolvedModel = model ?? deployment
        self.id = "azure.\(deployment)"
        self.endpoint = URL(string: "https://\(resource).openai.azure.com/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)")!
        self.transport = OpenAIProvider(
            apiKey: apiKey,
            model: resolvedModel,
            endpoint: endpoint,
            urlSession: urlSession,
            authHeaderField: "api-key",
            authValuePrefix: ""
        )
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// DeepInfra over `https://api.deepinfra.com/v1/openai` (Bearer). Turbo and
/// base service tiers share the endpoint; they differ by model ID suffix.
public final class DeepInfraProvider: LLMProvider, @unchecked Sendable {
    public static let turboDefaultModel = "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo"
    public static let baseDefaultModel = "meta-llama/Meta-Llama-3.1-70B-Instruct"

    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "DeepInfra"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = baseDefaultModel, urlSession: URLSession = .shared) {
        self.id = "deepinfra.\(model)"
        self.endpoint = URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Crusoe Cloud inference over `https://api.intelligence.crusoecloud.com/v1` (Bearer).
public final class CrusoeProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Crusoe"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct", urlSession: URLSession = .shared) {
        self.id = "crusoe.\(model)"
        self.endpoint = URL(string: "https://api.intelligence.crusoecloud.com/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Nebius AI Studio over `https://api.studio.nebius.com/v1` (Bearer).
public final class NebiusProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Nebius"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct", urlSession: URLSession = .shared) {
        self.id = "nebius.\(model)"
        self.endpoint = URL(string: "https://api.studio.nebius.com/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Baseten Model APIs (shared endpoint) over `https://inference.baseten.co/v1`
/// (Bearer). Per-deployment Truss URLs are not covered; use `CoreWeaveProvider`'s
/// explicit-endpoint pattern via a custom `OpenAIProvider` for those.
public final class BasetenProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Baseten"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-70B-Instruct", urlSession: URLSession = .shared) {
        self.id = "baseten.\(model)"
        self.endpoint = URL(string: "https://inference.baseten.co/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Google Vertex AI in Express mode over the global
/// `https://aiplatform.googleapis.com/v1/publishers/google/models` collection
/// with `x-goog-api-key` auth. Same Gemini shape as AI Studio; standard
/// project/service-account Vertex auth is not included.
public final class GoogleVertexProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    public let baseURL: String
    private let gemini: GoogleGeminiProvider

    public init(apiKey: String, model: String = "gemini-2.5-flash", urlSession: URLSession = .shared) {
        self.id = "vertex.\(model)"
        self.baseURL = "https://aiplatform.googleapis.com/v1/publishers/google/models"
        self.gemini = GoogleGeminiProvider(apiKey: apiKey, model: model, urlSession: urlSession, baseURL: baseURL)
        self.capabilities = gemini.capabilities
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "GoogleVertex")
        return try await gemini.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        gemini.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Parasail serverless inference over `https://api.saas.parasail.io/v1` (Bearer).
public final class ParasailProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Parasail"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "DeepSeek-R1", urlSession: URLSession = .shared) {
        self.id = "parasail.\(model)"
        self.endpoint = URL(string: "https://api.saas.parasail.io/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Amazon Bedrock over the OpenAI-compatible
/// `https://bedrock-runtime.{region}.amazonaws.com/v1/chat/completions`
/// route with a Bedrock API key (Bearer). SigV4/Converse is not included.
public final class BedrockProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Bedrock"
    private let transport: OpenAIProvider

    public init(
        apiKey: String,
        model: String = "anthropic.claude-sonnet-4-6",
        region: String = "us-east-1",
        urlSession: URLSession = .shared
    ) {
        self.id = "bedrock.\(model)"
        self.endpoint = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Together AI serverless inference over `https://api.together.xyz/v1` (Bearer).
public final class TogetherProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Together"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/Llama-3.3-70B-Instruct-Turbo", urlSession: URLSession = .shared) {
        self.id = "together.\(model)"
        self.endpoint = URL(string: "https://api.together.xyz/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Scaleway Generative APIs over `https://api.scaleway.ai/v1` (Bearer secret key).
public final class ScalewayProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Scaleway"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "mistral-small-3.2-24b-instruct-2506", urlSession: URLSession = .shared) {
        self.id = "scaleway.\(model)"
        self.endpoint = URL(string: "https://api.scaleway.ai/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Novita AI over `https://api.novita.ai/v3/openai` (Bearer).
public final class NovitaProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Novita"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/llama-3.1-8b-instruct", urlSession: URLSession = .shared) {
        self.id = "novita.\(model)"
        self.endpoint = URL(string: "https://api.novita.ai/v3/openai/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// CoreWeave inference over a host-supplied deployment URL. CoreWeave exposes
/// per-deployment OpenAI-compatible endpoints rather than one shared base URL,
/// so the endpoint is required and fails closed when absent.
public final class CoreWeaveProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "CoreWeave"
    private let transport: OpenAIProvider

    public init(apiKey: String, model: String = "meta-llama/Meta-Llama-3.1-8B-Instruct", endpoint: URL, urlSession: URLSession = .shared) {
        self.id = "coreweave.\(model)"
        self.endpoint = endpoint
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// Cloudflare Workers AI over the account-scoped
/// `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1`
/// OpenAI-compatible route (Bearer API token with Workers AI permission).
public final class CloudflareProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities = .cloudStandard
    public let endpoint: URL
    private let vendorLabel = "Cloudflare"
    private let transport: OpenAIProvider

    public init(apiKey: String, accountID: String, model: String = "@cf/meta/llama-3.1-8b-instruct", urlSession: URLSession = .shared) {
        self.id = "cloudflare.\(model)"
        self.endpoint = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/v1/chat/completions")!
        self.transport = OpenAIProvider(apiKey: apiKey, model: model, endpoint: endpoint, urlSession: urlSession)
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: vendorLabel)
        return try await transport.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        transport.stream(prompt: prompt, tools: tools, options: options)
    }
}
