import Foundation

/// Anthropic Messages API Provider supporting Claude 3.5 Sonnet, Claude 3.5 Haiku, and Claude 3 Opus.
public final class AnthropicProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    public let apiKey: String
    public let endpoint: URL
    public let model: String
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "claude-3-5-sonnet-20241022",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        capabilities: ModelCapabilities = .cloudStandard,
        urlSession: URLSession = .shared
    ) {
        self.id = "anthropic.\(model)"
        self.capabilities = capabilities
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
        try ZeroCloudMode.ensureAllowed(provider: "Anthropic")

        var systemPrompt: String? = nil
        var messages: [[String: Any]] = []

        for msg in PIISanitizer.sanitize(prompt: prompt) {
            if msg.role == .system {
                systemPrompt = msg.content
            } else {
                messages.append([
                    "role": msg.role == .assistant ? "assistant" : "user",
                    "content": msg.content
                ])
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": options.maxTokens ?? 4096
        ]

        if let sys = systemPrompt {
            payload["system"] = sys
        }
        if let temp = options.temperature {
            payload["temperature"] = temp
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map { t in
                [
                    "name": t.name,
                    "description": t.description,
                    "input_schema": t.parametersJSONSchema
                ]
            }
        }

        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let err = String(data: data, encoding: .utf8) ?? "Unknown Anthropic error"
            throw GraphError.toolExecutionFailed(toolName: "Anthropic", errorDescription: err)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = json["content"] as? [[String: Any]] else {
            throw GraphError.stateDeserializationFailed("Invalid Anthropic response format.")
        }

        var textOutput = ""
        var toolCalls: [ToolCall] = []

        for block in contents {
            let type = block["type"] as? String
            if type == "text" {
                textOutput += block["text"] as? String ?? ""
            } else if type == "tool_use" {
                let callId = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                var argsString = "{}"
                if let inputObj = block["input"],
                   let inputData = try? JSONSerialization.data(withJSONObject: inputObj),
                   let jsonStr = String(data: inputData, encoding: .utf8) {
                    argsString = jsonStr
                }
                toolCalls.append(ToolCall(id: callId, name: name, arguments: argsString))
            }
        }

        var usage: TokenUsage? = nil
        if let u = json["usage"] as? [String: Any] {
            let inputTokens = u["input_tokens"] as? Int ?? 0
            let outputTokens = u["output_tokens"] as? Int ?? 0
            usage = TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens, totalTokens: inputTokens + outputTokens)
        }

        return ModelResponse(
            text: textOutput,
            toolCalls: toolCalls,
            finishReason: json["stop_reason"] as? String,
            usage: usage
        )
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ZeroCloudMode.ensureAllowed(provider: "Anthropic")
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
