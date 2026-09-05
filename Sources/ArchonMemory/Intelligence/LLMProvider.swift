import Foundation
import ArchonCore

/// Provider interface for Memory Extraction and Reasoning.
public protocol LLMProvider: ArchonStructuredOutputProvider {}

/// Adapts the shared agent provider contract to the memory extraction API.
public struct ArchonMemoryProviderAdapter: LLMProvider, Sendable {
    private let provider: any ArchonStructuredOutputProvider

    public init(provider: any ArchonStructuredOutputProvider) {
        self.provider = provider
    }

    public func generateStructuredOutput<T: Decodable & Sendable>(
        prompt: String,
        responseSchema: T.Type
    ) async throws -> T {
        try await provider.generateStructuredOutput(prompt: prompt, responseSchema: responseSchema)
    }
}
