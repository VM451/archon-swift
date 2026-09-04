import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Errors specific to Apple's Private Cloud Compute runtime.
public enum PrivateCloudComputeError: Error, LocalizedError, Sendable, Equatable {
    case serviceUnavailable
    case cryptographicVerificationFailed(String)
    case contextWindowExceeded
    case networkError(String)
    case emptyPrompt
    case toolCallingUnsupported

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Apple Private Cloud Compute is not reachable or disabled in system settings."
        case .cryptographicVerificationFailed(let reason):
            return "PCC secure enclave cryptographic attestation failed: \(reason)"
        case .contextWindowExceeded:
            return "Prompt exceeded Private Cloud Compute maximum context length (65,536 tokens)."
        case .networkError(let message):
            return "Private Cloud Compute network communication error: \(message)"
        case .emptyPrompt:
            return "Private Cloud Compute generation requires a non-empty prompt."
        case .toolCallingUnsupported:
            return "Dynamic Archon tool definitions cannot be converted safely into Foundation Models Tool values."
        }
    }
}

public struct PrivateCloudComputeRuntimeResponse: Sendable, Equatable {
    public let text: String
    public let usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Injectable boundary around Apple's Private Cloud Compute model.
public protocol PrivateCloudComputeRuntime: Sendable {
    var isAvailable: Bool { get }

    func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> PrivateCloudComputeRuntimeResponse

    func stream(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

/// Production adapter for Apple's PrivateCloudComputeLanguageModel.
public struct ApplePrivateCloudComputeRuntime: PrivateCloudComputeRuntime, Sendable {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }

    public func respond(
        systemInstructions: String?,
        prompt: String,
        options: GenerationOptions
    ) async throws -> PrivateCloudComputeRuntimeResponse {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrivateCloudComputeError.emptyPrompt
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else {
                throw PrivateCloudComputeError.serviceUnavailable
            }
            let session = LanguageModelSession(model: model, instructions: systemInstructions)
            let foundationOptions = FoundationModels.GenerationOptions(
                temperature: options.temperature,
                maximumResponseTokens: options.maxTokens
            )
            let response = try await session.respond(to: prompt, options: foundationOptions)
            let usage = TokenUsage(
                promptTokens: response.usage.input.totalTokenCount,
                completionTokens: response.usage.output.totalTokenCount
            )
            return PrivateCloudComputeRuntimeResponse(text: response.content, usage: usage)
        }
        #endif

        throw PrivateCloudComputeError.serviceUnavailable
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
                        throw PrivateCloudComputeError.emptyPrompt
                    }

                    #if canImport(FoundationModels)
                    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                        let model = PrivateCloudComputeLanguageModel()
                        guard model.isAvailable else {
                            throw PrivateCloudComputeError.serviceUnavailable
                        }
                        let session = LanguageModelSession(model: model, instructions: systemInstructions)
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

                    throw PrivateCloudComputeError.serviceUnavailable
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

/// Provider for Apple's privacy-preserving cloud runtime.
///
/// Runtime calls use Apple's Foundation Models API. The provider does not
/// synthesize output when the service is unavailable.
public final class PrivateCloudComputeProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities: ModelCapabilities

    private let runtime: any PrivateCloudComputeRuntime
    private let simulatedDelay: TimeInterval
    private let mockResponses: MockResponseStore

    public static let `default` = PrivateCloudComputeProvider(id: "apple.pcc.default")

    public static var isAvailable: Bool {
        ApplePrivateCloudComputeRuntime().isAvailable
    }

    public init(
        id: String = "apple.privatecloudcompute.v1",
        capabilities: ModelCapabilities = .privateCloudCompute,
        simulatedDelay: TimeInterval = 0,
        mockResponses: [String: String] = [:],
        runtime: any PrivateCloudComputeRuntime = ApplePrivateCloudComputeRuntime()
    ) {
        self.id = id
        self.capabilities = capabilities
        self.simulatedDelay = simulatedDelay
        self.mockResponses = MockResponseStore(mockResponses)
        self.runtime = runtime
    }

    /// Registers an explicit deterministic response for offline tests.
    public func registerMockResponse(forPromptContaining substring: String, response: String) {
        mockResponses.set(response, for: substring)
    }

    public func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        guard !prompt.isEmpty else {
            throw PrivateCloudComputeError.emptyPrompt
        }
        guard tools.isEmpty else {
            throw PrivateCloudComputeError.toolCallingUnsupported
        }

        let transcript = FoundationModelsBridge.formatTranscript(for: prompt)
        guard !transcript.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrivateCloudComputeError.emptyPrompt
        }

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
        return ModelResponse(text: response.text, finishReason: "stop", usage: response.usage)
    }

    public func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !prompt.isEmpty else {
                        throw PrivateCloudComputeError.emptyPrompt
                    }
                    guard tools.isEmpty else {
                        throw PrivateCloudComputeError.toolCallingUnsupported
                    }

                    let transcript = FoundationModelsBridge.formatTranscript(for: prompt)
                    guard !transcript.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PrivateCloudComputeError.emptyPrompt
                    }

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

    private func mockResponse(for prompt: String) -> String? {
        mockResponses.response(for: prompt, caseSensitive: false)
    }
}
