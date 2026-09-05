import Foundation

/// Universal OpenAI Provider supporting GPT-4o, GPT-4o-mini, o1, and o3 endpoints.
public final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    private let apiKey: String
    public let endpoint: URL
    public let model: String
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-4o",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        capabilities: ModelCapabilities = .cloudStandard,
        urlSession: URLSession = .shared
    ) {
        self.id = "openai.\(model)"
        // This implementation performs one request and emits one response;
        // do not advertise incremental streaming until SSE is implemented.
        self.capabilities = capabilities.withStreaming(false)
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "OpenAI")

        var messagesPayload: [[String: Any]] = []
        for msg in PIISanitizer.sanitize(prompt: prompt) {
            var m: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
            if let calls = msg.toolCalls {
                m["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments]
                    ]
                }
            }
            if let toolCallId = msg.toolCallId {
                m["tool_call_id"] = toolCallId
            }
            messagesPayload.append(m)
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messagesPayload
        ]

        if let temp = options.temperature {
            payload["temperature"] = temp
        }
        if let maxT = options.maxTokens {
            payload["max_tokens"] = maxT
        }
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
        try LLMProviderResponsePolicy.validateRequest(bodyData, provider: "OpenAI")

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        try LLMProviderResponsePolicy.validate(data, provider: "OpenAI")
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphError.toolExecutionFailed(toolName: "OpenAI", errorDescription: "The provider returned an invalid HTTP response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GraphError.toolExecutionFailed(
                toolName: "OpenAI",
                errorDescription: "The provider returned HTTP status (httpResponse.statusCode)."
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw GraphError.stateDeserializationFailed("Invalid response format from OpenAI.")
        }

        let content = message["content"] as? String ?? ""
        var toolCalls: [ToolCall] = []

        if let callsRaw = message["tool_calls"] as? [[String: Any]] {
            for raw in callsRaw {
                let callId = raw["id"] as? String ?? UUID().uuidString
                if let fn = raw["function"] as? [String: Any],
                   let fnName = fn["name"] as? String,
                   let fnArgs = fn["arguments"] as? String {
                    toolCalls.append(ToolCall(id: callId, name: fnName, arguments: fnArgs))
                }
            }
        }

        let finishReason = firstChoice["finish_reason"] as? String

        var usage: TokenUsage? = nil
        if let usageRaw = json["usage"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: usageRaw["prompt_tokens"] as? Int ?? 0,
                completionTokens: usageRaw["completion_tokens"] as? Int ?? 0,
                totalTokens: usageRaw["total_tokens"] as? Int ?? 0
            )
        }

        return ModelResponse(text: content, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ZeroCloudMode.ensureAllowed(provider: "OpenAI")
                    let response = try await self.generate(prompt: prompt, tools: tools, options: options)
                    continuation.yield(ModelResponseChunk(deltaText: response.text))
                    if !response.toolCalls.isEmpty {
                        let chunks = response.toolCalls.enumerated().map { idx, call in
                            ToolCallChunk(index: idx, id: call.id, name: call.name, argumentsDelta: call.arguments)
                        }
                        continuation.yield(ModelResponseChunk(toolCallChunks: chunks))
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
