import Foundation

/// Google Gemini Provider supporting Gemini 1.5 Pro, Flash, and Gemini 2.0 Flash.
public final class GoogleGeminiProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    public let apiKey: String
    public let model: String
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gemini-1.5-pro",
        capabilities: ModelCapabilities = .cloudStandard,
        urlSession: URLSession = .shared
    ) {
        self.id = "google.\(model)"
        self.capabilities = capabilities
        self.apiKey = apiKey
        self.model = model
        self.urlSession = urlSession
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "GoogleGemini")

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GraphError.toolExecutionFailed(toolName: "GoogleGemini", errorDescription: "Invalid URL.")
        }

        var contents: [[String: Any]] = []
        for msg in PIISanitizer.sanitize(prompt: prompt) {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append([
                "role": role,
                "parts": [["text": msg.content]]
            ])
        }

        var payload: [String: Any] = ["contents": contents]
        if !tools.isEmpty {
            let declarations = tools.map { t in
                [
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parametersJSONSchema
                ]
            }
            payload["tools"] = [["function_declarations": declarations]]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let err = String(data: data, encoding: .utf8) ?? "Unknown Google Gemini error"
            throw GraphError.toolExecutionFailed(toolName: "GoogleGemini", errorDescription: err)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let candidateContent = firstCandidate["content"] as? [String: Any],
              let parts = candidateContent["parts"] as? [[String: Any]] else {
            throw GraphError.stateDeserializationFailed("Invalid Gemini response format.")
        }

        var textOutput = ""
        var toolCalls: [ToolCall] = []

        for part in parts {
            if let text = part["text"] as? String {
                textOutput += text
            }
            if let functionCall = part["functionCall"] as? [String: Any] {
                let name = functionCall["name"] as? String ?? ""
                var argsStr = "{}"
                if let args = functionCall["args"],
                   let argsData = try? JSONSerialization.data(withJSONObject: args),
                   let s = String(data: argsData, encoding: .utf8) {
                    argsStr = s
                }
                toolCalls.append(ToolCall(id: UUID().uuidString, name: name, arguments: argsStr))
            }
        }

        return ModelResponse(
            text: textOutput,
            toolCalls: toolCalls,
            finishReason: firstCandidate["finishReason"] as? String
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
                    try ZeroCloudMode.ensureAllowed(provider: "GoogleGemini")
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
