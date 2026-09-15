import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Errors raised while using Apple's system Foundation Model runtime.
public enum AppleFoundationModelError: Error, LocalizedError, Sendable, Equatable {
    case modelUnavailable
    case hardwareAccelerationFailed(String)
    case contextWindowExceeded
    case emptyPrompt
    case toolCallingUnsupported
    case invalidOptions(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Foundation Model is not available on this device."
        case .hardwareAccelerationFailed(let reason):
            return "Apple Foundation Model execution failed: \(reason)"
        case .contextWindowExceeded:
            return "Context tokens exceeded the local on-device limit."
        case .emptyPrompt:
            return "Apple Foundation Model generation requires a non-empty prompt."
        case .toolCallingUnsupported:
            return "Dynamic Archon tool definitions cannot be converted safely into Foundation Models Tool values."
        case .invalidOptions(let reason):
            return "Apple Foundation Model generation options are invalid: \(reason)"
        }
    }
}

public struct AppleFoundationModelRuntimeResponse: Sendable, Equatable {
    public let text: String
    public let usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Injectable boundary around Apple's Foundation Models APIs.
///
/// Applications use the default FoundationModelsRuntime. Tests can inject a
/// deterministic runtime without making network calls or requiring Apple
/// Intelligence assets to be available on the host.
public protocol AppleFoundationModelRuntime: Sendable {
    var isAvailable: Bool { get }

    func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AppleFoundationModelRuntimeResponse

    func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

/// Production adapter for Apple's SystemLanguageModel and
/// LanguageModelSession.
public struct FoundationModelsRuntime: AppleFoundationModelRuntime, Sendable {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AppleFoundationModelRuntimeResponse {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleFoundationModelError.emptyPrompt
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            guard isAvailable else {
                throw AppleFoundationModelError.modelUnavailable
            }
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: systemInstructions
            )
            let foundationOptions = FoundationModels.GenerationOptions(
                temperature: options.temperature,
                maximumResponseTokens: options.maxTokens
            )
            let response = try await session.respond(to: prompt, options: foundationOptions)
            let promptTokens = response.usage.input.totalTokenCount
            let completionTokens = response.usage.output.totalTokenCount
            let usage = TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
            return AppleFoundationModelRuntimeResponse(text: response.content, usage: usage)
        }
        #endif

        throw AppleFoundationModelError.modelUnavailable
    }

    public func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppleFoundationModelError.emptyPrompt
                    }

                    #if canImport(FoundationModels)
                    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                        guard isAvailable else {
                            throw AppleFoundationModelError.modelUnavailable
                        }
                        let session = LanguageModelSession(
                            model: SystemLanguageModel.default,
                            instructions: systemInstructions
                        )
                        let foundationOptions = FoundationModels.GenerationOptions(
                            temperature: options.temperature,
                            maximumResponseTokens: options.maxTokens
                        )
                        var previousText = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: foundationOptions) {
                            try Task.checkCancellation()
                            let currentText = snapshot.content
                            let delta: String
                            if currentText.hasPrefix(previousText) {
                                delta = String(currentText.dropFirst(previousText.count))
                            } else {
                                delta = currentText
                            }
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            previousText = currentText
                        }
                        continuation.finish()
                        return
                    }
                    #endif

                    throw AppleFoundationModelError.modelUnavailable
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

/// Provider for Apple's local system model.
///
/// The provider never synthesizes a response when the system model is absent.
/// registerMockResponse is intentionally explicit and exists for deterministic
/// unit tests and host-app previews.
public final class AppleFoundationModelProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities

    private let runtime: any AppleFoundationModelRuntime
    private let simulatedDelay: TimeInterval
    private let mockResponses: MockResponseStore

    public static let `default` = AppleFoundationModelProvider(id: "apple.foundation.default")

    /// Whether Apple's system model reports itself as available on this device.
    public static var isAvailable: Bool {
        FoundationModelsRuntime().isAvailable
    }

    public init(
        id: String = "apple.foundation.v1",
        capabilities: ModelCapabilities = .appleFoundation,
        simulatedDelay: TimeInterval = 0,
        mockResponses: [String: String] = [:],
        runtime: any AppleFoundationModelRuntime = FoundationModelsRuntime()
    ) {
        self.id = id
        self.capabilities = capabilities
        self.simulatedDelay = simulatedDelay
        self.mockResponses = MockResponseStore(mockResponses)
        self.runtime = runtime
    }

    /// Registers an explicit deterministic response for tests or previews.
    public func registerMockResponse(forPromptContaining substring: String, response: String) {
        mockResponses.set(response, for: substring)
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        let transcript = try validatedTranscript(prompt: prompt, tools: tools, options: options)

        if let mock = mockResponse(for: transcript.userPrompt) {
            if simulatedDelay > 0 {
                try await Task.sleep(for: .seconds(simulatedDelay))
            }
            let completionTokens = mock.split(whereSeparator: \.isWhitespace).count
            return ModelResponse(
                text: mock,
                finishReason: "stop",
                usage: TokenUsage(
                    promptTokens: 0,
                    completionTokens: completionTokens,
                    totalTokens: completionTokens
                )
            )
        }

        try Task.checkCancellation()
        let response = try await runtime.respond(
            systemInstructions: transcript.systemInstruction,
            prompt: transcript.userPrompt,
            options: options
        )
        return ModelResponse(text: response.text, finishReason: "stop", usage: Self.normalizedUsage(response.usage))
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcript = try self.validatedTranscript(prompt: prompt, tools: tools, options: options)

                    if let mock = self.mockResponse(for: transcript.userPrompt) {
                        for word in mock.split(whereSeparator: \.isWhitespace) {
                            try Task.checkCancellation()
                            continuation.yield(ModelResponseChunk(deltaText: String(word) + " "))
                            if self.simulatedDelay > 0 {
                                try await Task.sleep(for: .seconds(self.simulatedDelay))
                            }
                        }
                        continuation.yield(ModelResponseChunk(isFinished: true))
                        continuation.finish()
                        return
                    }

                    for try await delta in self.runtime.stream(
                        systemInstructions: transcript.systemInstruction,
                        prompt: transcript.userPrompt,
                        options: options
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(ModelResponseChunk(deltaText: delta))
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

    private func validatedTranscript(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) throws -> (systemInstruction: String?, userPrompt: String) {
        guard !LocalRequestValidation.isEffectivelyEmpty(prompt) else {
            throw AppleFoundationModelError.emptyPrompt
        }
        guard tools.isEmpty else {
            throw AppleFoundationModelError.toolCallingUnsupported
        }
        if let problem = LocalRequestValidation.optionsProblem(options) {
            throw AppleFoundationModelError.invalidOptions(problem)
        }
        let transcript = FoundationModelsBridge.formatTranscript(for: prompt)
        guard !transcript.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleFoundationModelError.emptyPrompt
        }
        let estimatedTokens = LocalRequestValidation.estimatedTokenCount(for: prompt)
        guard estimatedTokens <= capabilities.maxContextTokens else {
            throw AppleFoundationModelError.contextWindowExceeded
        }
        return transcript
    }

    private static func normalizedUsage(_ usage: TokenUsage?) -> TokenUsage? {
        guard let usage else { return nil }
        let total = usage.promptTokens + usage.completionTokens
        guard usage.totalTokens != total else { return usage }
        return TokenUsage(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: total
        )
    }

    private func mockResponse(for prompt: String) -> String? {
        mockResponses.response(for: prompt, caseSensitive: false)
    }
}
