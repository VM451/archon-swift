import Foundation

/// Universal OpenAI Provider supporting GPT-4o, GPT-4o-mini, o1, and o3 endpoints.
/// Also the shared transport for the OpenAI-compatible `MistralProvider`,
/// `GrokProvider`, and `OpenRouterProvider` wrappers, which only override the
/// endpoint URL and provider id.
public final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities
    private let apiKey: String
    public let endpoint: URL
    public let model: String
    private let urlSession: URLSession

    private let authHeaderField: String
    private let authValuePrefix: String

    public init(
        apiKey: String,
        model: String = "gpt-4o",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        capabilities: ModelCapabilities = .cloudStandard,
        urlSession: URLSession = .shared,
        authHeaderField: String = "Authorization",
        authValuePrefix: String = "Bearer "
    ) {
        self.id = "openai.\(model)"
        self.capabilities = capabilities
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
        self.authHeaderField = authHeaderField
        self.authValuePrefix = authValuePrefix
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        try ZeroCloudMode.ensureAllowed(provider: "OpenAI")

        let bodyData = try Self.requestBody(
            model: model,
            prompt: prompt,
            tools: tools,
            options: options,
            stream: false
        )
        try LLMProviderResponsePolicy.validateRequest(bodyData, provider: "OpenAI")

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue("\(authValuePrefix)\(apiKey)", forHTTPHeaderField: authHeaderField)
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
                errorDescription: "The provider returned HTTP status \(httpResponse.statusCode)."
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

    /// Incremental SSE streaming over the OpenAI-compatible
    /// `text/event-stream` transport (`stream: true`). Each `data:` event
    /// yields one `ModelResponseChunk`; `data: [DONE]` ends the stream.
    /// Malformed events are skipped so one bad line never kills the stream;
    /// HTTP errors fail before the first event is read.
    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ZeroCloudMode.ensureAllowed(provider: "OpenAI")
                    let bodyData = try Self.requestBody(
                        model: model,
                        prompt: prompt,
                        tools: tools,
                        options: options,
                        stream: true
                    )
                    try LLMProviderResponsePolicy.validateRequest(bodyData, provider: "OpenAI")

                    var request = URLRequest(url: endpoint)
                    request.timeoutInterval = 120
                    request.httpMethod = "POST"
                    request.setValue("\(authValuePrefix)\(apiKey)", forHTTPHeaderField: authHeaderField)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = bodyData

                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw GraphError.toolExecutionFailed(toolName: "OpenAI", errorDescription: "The provider returned an invalid HTTP response.")
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw GraphError.toolExecutionFailed(
                            toolName: "OpenAI",
                            errorDescription: "The provider returned HTTP status \(httpResponse.statusCode)."
                        )
                    }

                    var streamedBytes = 0
                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        streamedBytes += rawLine.utf8.count
                        if streamedBytes > LLMProviderResponsePolicy.maximumResponseBytes {
                            throw GraphError.toolExecutionFailed(
                                toolName: "OpenAI",
                                errorDescription: "Provider response exceeded the configured size limit."
                            )
                        }
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { continue }
                        if Self.isStreamDoneLine(line) {
                            continuation.yield(ModelResponseChunk(isFinished: true))
                            continuation.finish()
                            return
                        }
                        if let chunk = Self.parseStreamLine(line) {
                            continuation.yield(chunk)
                        }
                    }
                    // Some transports close without `data: [DONE]`; a clean
                    // EOF still ends the turn instead of hanging the caller.
                    continuation.yield(ModelResponseChunk(isFinished: true))
                    continuation.finish()
                } catch is CancellationError {
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

    // MARK: - Request building (pure, unit-tested)

    /// Encodes a message body, expanding vision attachments into Chat
    /// Completions content parts (`text` + `image_url` data URLs) so camera
    /// and screen frames reach multimodal models.
    static func messageContent(for message: ChatMessage) -> Any {
        guard let attachments = message.attachments, !attachments.isEmpty else {
            return message.content
        }
        var parts: [[String: Any]] = [["type": "text", "text": message.content]]
        for attachment in attachments {
            let url = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": url]])
        }
        return parts
    }

    static func requestBody(
        model: String,
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions,
        stream: Bool
    ) throws -> Data {
        var messagesPayload: [[String: Any]] = []
        for msg in PIISanitizer.sanitize(prompt: prompt) {
            var m: [String: Any] = ["role": msg.role.rawValue, "content": Self.messageContent(for: msg)]
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
        if stream {
            payload["stream"] = true
        }
        if let temp = options.temperature {
            payload["temperature"] = temp
        }
        if let topP = options.topP {
            payload["top_p"] = topP
        }
        if let maxT = options.maxTokens {
            payload["max_tokens"] = maxT
        }
        if !options.stopSequences.isEmpty {
            payload["stop"] = options.stopSequences
        }
        if options.responseFormatJSON {
            payload["response_format"] = ["type": "json_object"]
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        // `AnySendable` wrappers are not JSON-serializable;
                        // unwrap to plain values or serialization traps.
                        "parameters": Self.jsonCompatible(t.parametersJSONSchema)
                    ]
                ]
            }
        }

        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Recursively unwraps `AnySendable` values into plain JSON-compatible
    /// values (`String`/`Double`/`Bool`/arrays/objects). Unknown leaves
    /// become `NSNull` rather than trapping serialization.
    static func jsonCompatible(_ value: Any) -> Any {
        if let sendable = value as? AnySendable {
            return jsonCompatible(sendable.value)
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { jsonCompatible($0) }
        }
        if let array = value as? [Any] {
            return array.map { jsonCompatible($0) }
        }
        switch value {
        case is String, is Bool, is Int, is Double, is Float, is NSNull:
            return value
        default:
            return NSNull()
        }
    }

    // MARK: - SSE parsing (pure, unit-tested)

    /// True for the terminal `data: [DONE]` event (whitespace tolerant).
    static func isStreamDoneLine(_ line: String) -> Bool {
        guard let payload = ssePayload(from: line) else { return false }
        return payload == "[DONE]"
    }

    /// Parses one SSE `data:` line into a stream chunk. Returns nil for
    /// comments, blank lines, the terminal `[DONE]` marker, and malformed
    /// events (fail-open per event so one bad line never kills the stream).
    static func parseStreamLine(_ line: String) -> ModelResponseChunk? {
        guard let payload = ssePayload(from: line),
              payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }

        let deltaText = delta["content"] as? String
        var toolCallChunks: [ToolCallChunk]?
        if let callsRaw = delta["tool_calls"] as? [[String: Any]] {
            let parsed = callsRaw.enumerated().compactMap { index, raw -> ToolCallChunk? in
                let fn = raw["function"] as? [String: Any]
                let callId = raw["id"] as? String
                let name = fn?["name"] as? String
                let args = fn?["arguments"] as? String
                guard callId != nil || name != nil || args != nil else { return nil }
                return ToolCallChunk(
                    index: raw["index"] as? Int ?? index,
                    id: callId,
                    name: name,
                    argumentsDelta: args
                )
            }
            if !parsed.isEmpty {
                toolCallChunks = parsed
            }
        }
        guard deltaText != nil || toolCallChunks != nil else { return nil }
        return ModelResponseChunk(deltaText: deltaText, toolCallChunks: toolCallChunks)
    }

    /// Extracts the event payload from an SSE line. Only `data:` lines
    /// carry chat events; comments (`:`) and other fields yield nil.
    private static func ssePayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        return trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    }
}
