import Foundation
import Testing

@testable import ArchonAgent

// MARK: - Request-capturing stub

private final class CaptureStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func takeRequests() -> [URLRequest] {
        lock.withLock {
            let captured = requests
            requests = []
            return captured
        }
    }

    /// Takes only requests to `host`, leaving other tests' captures alone.
    static func takeRequests(host: String) -> [URLRequest] {
        lock.withLock {
            let captured = requests.filter { $0.url?.host == host }
            requests.removeAll { $0.url?.host == host }
            return captured
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let body = """
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CaptureStub.self]
    return URLSession(configuration: configuration)
}

// MARK: - Suite

@Suite("Cloud Inference Providers Tests")
struct CloudInferenceProvidersTests {
    @Test("Fixed-endpoint providers carry their vendor endpoint and default id")
    func fixedEndpoints() {
        let cases: [(any LLMProvider, String, String)] = [
            (CerebrasProvider(apiKey: "k"), "cerebras.llama-3.3-70b", "https://api.cerebras.ai/v1/chat/completions"),
            (SambaNovaProvider(apiKey: "k"), "sambanova.Meta-Llama-3.3-70B-Instruct", "https://api.sambanova.ai/v1/chat/completions"),
            (GroqProvider(apiKey: "k"), "groq.llama-3.3-70b-versatile", "https://api.groq.com/openai/v1/chat/completions"),
            (DeepInfraProvider(apiKey: "k"), "deepinfra.meta-llama/Meta-Llama-3.1-70B-Instruct", "https://api.deepinfra.com/v1/openai/chat/completions"),
            (CrusoeProvider(apiKey: "k"), "crusoe.meta-llama/Meta-Llama-3.1-8B-Instruct", "https://api.intelligence.crusoecloud.com/v1/chat/completions"),
            (NebiusProvider(apiKey: "k"), "nebius.meta-llama/Meta-Llama-3.1-70B-Instruct", "https://api.studio.nebius.com/v1/chat/completions"),
            (BasetenProvider(apiKey: "k"), "baseten.meta-llama/Meta-Llama-3.1-70B-Instruct", "https://inference.baseten.co/v1/chat/completions"),
            (ParasailProvider(apiKey: "k"), "parasail.DeepSeek-R1", "https://api.saas.parasail.io/v1/chat/completions"),
            (TogetherProvider(apiKey: "k"), "together.meta-llama/Llama-3.3-70B-Instruct-Turbo", "https://api.together.xyz/v1/chat/completions"),
            (ScalewayProvider(apiKey: "k"), "scaleway.mistral-small-3.2-24b-instruct-2506", "https://api.scaleway.ai/v1/chat/completions"),
            (NovitaProvider(apiKey: "k"), "novita.meta-llama/llama-3.1-8b-instruct", "https://api.novita.ai/v3/openai/chat/completions")
        ]
        for (provider, expectedID, expectedURL) in cases {
            #expect(provider.id == expectedID)
            #expect(provider.capabilities.supportsStreaming)
            #expect(provider.capabilities.supportsToolCalling)
            let endpoint: URL? = switch provider {
            case let p as CerebrasProvider: p.endpoint
            case let p as SambaNovaProvider: p.endpoint
            case let p as GroqProvider: p.endpoint
            case let p as DeepInfraProvider: p.endpoint
            case let p as CrusoeProvider: p.endpoint
            case let p as NebiusProvider: p.endpoint
            case let p as BasetenProvider: p.endpoint
            case let p as ParasailProvider: p.endpoint
            case let p as TogetherProvider: p.endpoint
            case let p as ScalewayProvider: p.endpoint
            case let p as NovitaProvider: p.endpoint
            default: nil
            }
            #expect(endpoint?.absoluteString == expectedURL)
        }
    }

    @Test("DeepInfra Turbo and base tiers share the endpoint with distinct defaults")
    func deepInfraTiers() {
        #expect(DeepInfraProvider.turboDefaultModel.hasSuffix("-Turbo"))
        let turbo = DeepInfraProvider(apiKey: "k", model: DeepInfraProvider.turboDefaultModel)
        let base = DeepInfraProvider(apiKey: "k")
        #expect(turbo.endpoint == base.endpoint)
        #expect(turbo.id != base.id)
        #expect(ArchonAI.model(.deepInfraTurbo(apiKey: "k")).id == turbo.id)
        #expect(ArchonAI.model(.deepInfra(apiKey: "k")).id == base.id)
    }

    @Test("Azure builds deployment URLs and defaults the model to the deployment")
    func azureEndpoint() {
        let provider = AzureOpenAIProvider(apiKey: "k", resource: "myres", deployment: "gpt-4o-prod")
        #expect(provider.id == "azure.gpt-4o-prod")
        #expect(provider.endpoint.absoluteString == "https://myres.openai.azure.com/openai/deployments/gpt-4o-prod/chat/completions?api-version=2025-04-01-preview")
        let viaEnum = ArchonAI.model(.azure(apiKey: "k", resource: "myres", deployment: "d1"))
        #expect(viaEnum is AzureOpenAIProvider)
        let viaShortcut = ArchonAI.azure(apiKey: "k", resource: "r", deployment: "d2", apiVersion: "2024-10-01-preview")
        #expect((viaShortcut as? AzureOpenAIProvider)?.endpoint.absoluteString.contains("api-version=2024-10-01-preview") == true)
    }

    @Test("Azure sends the api-key header without a Bearer prefix")
    func azureHeader() async throws {
        _ = CaptureStub.takeRequests(host: "myres.openai.azure.com")
        let provider = AzureOpenAIProvider(apiKey: "secret", resource: "myres", deployment: "d", urlSession: stubbedSession())
        let response = try await provider.generate(prompt: [.user("hi")], tools: [], options: GenerationOptions())
        #expect(response.text == "ok")
        let requests = CaptureStub.takeRequests(host: "myres.openai.azure.com")
        let captured = try #require(requests.first)
        #expect(captured.value(forHTTPHeaderField: "api-key") == "secret")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Standard wrappers keep Bearer authorization")
    func bearerDefault() async throws {
        _ = CaptureStub.takeRequests(host: "api.groq.com")
        let provider = GroqProvider(apiKey: "secret", urlSession: stubbedSession())
        _ = try await provider.generate(prompt: [.user("hi")], tools: [], options: GenerationOptions())
        let requests = CaptureStub.takeRequests(host: "api.groq.com")
        let captured = try #require(requests.first)
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(captured.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test("Vertex uses the Express collection with Gemini shape")
    func vertexEndpoint() {
        let provider = GoogleVertexProvider(apiKey: "k")
        #expect(provider.id == "vertex.gemini-2.5-flash")
        #expect(provider.baseURL == "https://aiplatform.googleapis.com/v1/publishers/google/models")
        #expect(ArchonAI.model(.vertex(apiKey: "k")) is GoogleVertexProvider)
        #expect(ArchonAI.vertex(apiKey: "k", model: "gemini-2.5-pro").id == "vertex.gemini-2.5-pro")
    }

    @Test("Bedrock interpolates the region into the runtime route")
    func bedrockEndpoint() {
        let provider = BedrockProvider(apiKey: "k")
        #expect(provider.id == "bedrock.anthropic.claude-sonnet-4-6")
        #expect(provider.endpoint.absoluteString == "https://bedrock-runtime.us-east-1.amazonaws.com/v1/chat/completions")
        let eu = BedrockProvider(apiKey: "k", region: "eu-west-1")
        #expect(eu.endpoint.absoluteString == "https://bedrock-runtime.eu-west-1.amazonaws.com/v1/chat/completions")
        #expect(ArchonAI.model(.bedrock(apiKey: "k")) is BedrockProvider)
        #expect(ArchonAI.bedrock(apiKey: "k").id == provider.id)
    }

    @Test("CoreWeave requires an explicit deployment endpoint")
    func coreWeaveEndpoint() {
        let url = URL(string: "https://inference.example.coreweave.cloud/v1/chat/completions")!
        let provider = CoreWeaveProvider(apiKey: "k", endpoint: url)
        #expect(provider.endpoint == url)
        #expect(ArchonAI.model(.coreWeave(apiKey: "k", endpoint: url)) is CoreWeaveProvider)
        #expect(ArchonAI.coreWeave(apiKey: "k", endpoint: url).id == provider.id)
    }

    @Test("Cloudflare embeds the account id in the Workers AI route")
    func cloudflareEndpoint() {
        let provider = CloudflareProvider(apiKey: "k", accountID: "acct123")
        #expect(provider.id == "cloudflare.@cf/meta/llama-3.1-8b-instruct")
        #expect(provider.endpoint.absoluteString == "https://api.cloudflare.com/client/v4/accounts/acct123/ai/v1/chat/completions")
        #expect(ArchonAI.model(.cloudflare(apiKey: "k", accountID: "acct123")) is CloudflareProvider)
        #expect(ArchonAI.cloudflare(apiKey: "k", accountID: "a").id.hasPrefix("cloudflare.") == true)
    }

    @Test("Every new provider resolves through the unified enum and shortcut")
    func factoryCoverage() {
        let viaEnum: [(any LLMProvider, String)] = [
            (ArchonAI.model(.cerebras(apiKey: "k")), "cerebras.llama-3.3-70b"),
            (ArchonAI.model(.sambaNova(apiKey: "k")), "sambanova.Meta-Llama-3.3-70B-Instruct"),
            (ArchonAI.model(.groq(apiKey: "k")), "groq.llama-3.3-70b-versatile"),
            (ArchonAI.model(.crusoe(apiKey: "k")), "crusoe.meta-llama/Meta-Llama-3.1-8B-Instruct"),
            (ArchonAI.model(.nebius(apiKey: "k")), "nebius.meta-llama/Meta-Llama-3.1-70B-Instruct"),
            (ArchonAI.model(.baseten(apiKey: "k")), "baseten.meta-llama/Meta-Llama-3.1-70B-Instruct"),
            (ArchonAI.model(.vertex(apiKey: "k")), "vertex.gemini-2.5-flash"),
            (ArchonAI.model(.parasail(apiKey: "k")), "parasail.DeepSeek-R1"),
            (ArchonAI.model(.bedrock(apiKey: "k")), "bedrock.anthropic.claude-sonnet-4-6"),
            (ArchonAI.model(.together(apiKey: "k")), "together.meta-llama/Llama-3.3-70B-Instruct-Turbo"),
            (ArchonAI.model(.scaleway(apiKey: "k")), "scaleway.mistral-small-3.2-24b-instruct-2506"),
            (ArchonAI.model(.novita(apiKey: "k")), "novita.meta-llama/llama-3.1-8b-instruct"),
            (ArchonAI.model(.deepInfra(apiKey: "k")), "deepinfra.meta-llama/Meta-Llama-3.1-70B-Instruct")
        ]
        for (provider, expectedID) in viaEnum {
            #expect(provider.id == expectedID)
        }
        #expect(ArchonAI.model(.cerebras(apiKey: "k")) is CerebrasProvider)
        #expect(ArchonAI.model(.sambaNova(apiKey: "k")) is SambaNovaProvider)
        #expect(ArchonAI.model(.groq(apiKey: "k")) is GroqProvider)
        #expect(ArchonAI.model(.crusoe(apiKey: "k")) is CrusoeProvider)
        #expect(ArchonAI.model(.nebius(apiKey: "k")) is NebiusProvider)
        #expect(ArchonAI.model(.baseten(apiKey: "k")) is BasetenProvider)
        #expect(ArchonAI.model(.parasail(apiKey: "k")) is ParasailProvider)
        #expect(ArchonAI.model(.together(apiKey: "k")) is TogetherProvider)
        #expect(ArchonAI.model(.scaleway(apiKey: "k")) is ScalewayProvider)
        #expect(ArchonAI.model(.novita(apiKey: "k")) is NovitaProvider)
        #expect(ArchonAI.cerebras(apiKey: "k").id == "cerebras.llama-3.3-70b")
        #expect(ArchonAI.sambaNova(apiKey: "k").id == "sambanova.Meta-Llama-3.3-70B-Instruct")
        #expect(ArchonAI.groq(apiKey: "k").id == "groq.llama-3.3-70b-versatile")
        #expect(ArchonAI.deepInfra(apiKey: "k").id == "deepinfra." + DeepInfraProvider.turboDefaultModel)
        #expect(ArchonAI.crusoe(apiKey: "k") is CrusoeProvider)
        #expect(ArchonAI.nebius(apiKey: "k") is NebiusProvider)
        #expect(ArchonAI.baseten(apiKey: "k") is BasetenProvider)
        #expect(ArchonAI.parasail(apiKey: "k") is ParasailProvider)
        #expect(ArchonAI.together(apiKey: "k") is TogetherProvider)
        #expect(ArchonAI.scaleway(apiKey: "k") is ScalewayProvider)
        #expect(ArchonAI.novita(apiKey: "k") is NovitaProvider)
    }

    @Test("Cloud adapters refuse generation under ZeroCloud policy")
    func zeroCloudRefusal() async {
        await ZeroCloudMode.withEnabled {
            await #expect(throws: Error.self) {
                try await GroqProvider(apiKey: "k").generate(prompt: [.user("hi")], tools: [], options: GenerationOptions())
            }
            await #expect(throws: Error.self) {
                try await GoogleVertexProvider(apiKey: "k").generate(prompt: [.user("hi")], tools: [], options: GenerationOptions())
            }
        }
    }
}
