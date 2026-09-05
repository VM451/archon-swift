import Foundation

/// Ollama / Local Llama Provider for local on-device servers and GGUF model runners.
public final class OllamaProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    public let endpoint: URL
    public let model: String
    private let urlSession: URLSession

    public init(
        model: String = "llama3.3",
        endpoint: URL = URL(string: "http://localhost:11434/api/chat")!,
        capabilities: ModelCapabilities = .appleFoundation,
        urlSession: URLSession = .shared
    ) {
        self.id = "ollama.\(model)"
        self.capabilities = capabilities.withStreaming(false)
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try ZeroCloudMode.ensureOllamaEndpointAllowed(endpoint)
        let messages = prompt.map { ["role": $0.role.rawValue, "content": $0.content] }
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]

        if !tools.isEmpty {
            payload["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parametersJSONSchema
                    ]
                ]
            }
        }

        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        try LLMProviderResponsePolicy.validateRequest(bodyData, provider: "Ollama")

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        try LLMProviderResponsePolicy.validate(data, provider: "Ollama")
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphError.toolExecutionFailed(toolName: "Ollama", errorDescription: "The provider returned an invalid HTTP response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GraphError.toolExecutionFailed(
                toolName: "Ollama",
                errorDescription: "The provider returned HTTP status (httpResponse.statusCode)."
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw GraphError.stateDeserializationFailed("Invalid Ollama response.")
        }

        let content = message["content"] as? String ?? ""
        var toolCalls: [ToolCall] = []

        if let callsRaw = message["tool_calls"] as? [[String: Any]] {
            for raw in callsRaw {
                if let fn = raw["function"] as? [String: Any],
                   let name = fn["name"] as? String {
                    let args = fn["arguments"] as? [String: Any] ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                    let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                    toolCalls.append(ToolCall(id: UUID().uuidString, name: name, arguments: argsStr))
                }
            }
        }

        return ModelResponse(text: content, toolCalls: toolCalls)
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.generate(prompt: prompt, tools: tools, options: options)
                    continuation.yield(ModelResponseChunk(deltaText: response.text))
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

/// Mistral AI Provider supporting Mistral Large, Codestral, and Pixtral.
public final class MistralProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    private let openAIWrapper: OpenAIProvider

    public init(
        apiKey: String,
        model: String = "mistral-large-latest",
        urlSession: URLSession = .shared
    ) {
        self.id = "mistral.\(model)"
        self.capabilities = .cloudStandard.withStreaming(false)
        self.openAIWrapper = OpenAIProvider(
            apiKey: apiKey,
            model: model,
            endpoint: URL(string: "https://api.mistral.ai/v1/chat/completions")!,
            capabilities: .cloudStandard,
            urlSession: urlSession
        )
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "Mistral")
        return try await openAIWrapper.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        openAIWrapper.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// xAI Grok Provider supporting Grok-2 and Grok-beta.
public final class GrokProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    private let openAIWrapper: OpenAIProvider

    public init(
        apiKey: String,
        model: String = "grok-2-latest",
        urlSession: URLSession = .shared
    ) {
        self.id = "xai.\(model)"
        self.capabilities = .cloudStandard.withStreaming(false)
        self.openAIWrapper = OpenAIProvider(
            apiKey: apiKey,
            model: model,
            endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
            capabilities: .cloudStandard,
            urlSession: urlSession
        )
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "xAI.Grok")
        return try await openAIWrapper.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        openAIWrapper.stream(prompt: prompt, tools: tools, options: options)
    }
}

/// NVIDIA NIM Provider supporting open LLM inference models accelerated by NVIDIA TensorRT-LLM.
public final class NvidiaProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    private let openAIWrapper: OpenAIProvider

    public init(
        apiKey: String,
        model: String = "meta/llama-3.3-70b-instruct",
        urlSession: URLSession = .shared
    ) {
        self.id = "nvidia.\(model)"
        self.capabilities = .cloudStandard.withStreaming(false)
        self.openAIWrapper = OpenAIProvider(
            apiKey: apiKey,
            model: model,
            endpoint: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!,
            capabilities: .cloudStandard,
            urlSession: urlSession
        )
    }

    public func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "NvidiaNIM")
        return try await openAIWrapper.generate(prompt: prompt, tools: tools, options: options)
    }

    public func stream(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        openAIWrapper.stream(prompt: prompt, tools: tools, options: options)
    }
}
