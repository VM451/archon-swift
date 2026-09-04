import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum MemoryFoundationProviderError: Error, LocalizedError, Equatable, Sendable {
    case embeddingUnavailable
    case modelUnavailable
    case invalidStructuredResponse

    public var errorDescription: String? {
        switch self {
        case .embeddingUnavailable:
            return "A native Natural Language embedding model is unavailable."
        case .modelUnavailable:
            return "Apple Foundation Model is unavailable for memory extraction."
        case .invalidStructuredResponse:
            return "Apple Foundation Model returned invalid structured memory JSON."
        }
    }
}

/// On-device privacy-preserving provider leveraging Apple's NaturalLanguage (NLEmbedding) and Apple Foundation Models / Guided Generation.
public final class AppleFoundationModelProvider: EmbeddingProvider, LLMProvider, @unchecked Sendable {
    public let vectorDimension: Int
    private let embedder: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.embedder = NLEmbedding.wordEmbedding(for: language)
        self.vectorDimension = embedder?.dimension ?? 512
    }

    // MARK: - EmbeddingProvider Implementation

    public func embed(text: String) async throws -> [Float] {
        guard let embedder = embedder else { throw MemoryFoundationProviderError.embeddingUnavailable }
        
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return [Float](repeating: 0.0, count: vectorDimension)
        }
        
        var accumVector = [Float](repeating: 0.0, count: vectorDimension)
        var count: Float = 0.0
        
        for word in words {
            if let vectorDouble = embedder.vector(for: word) {
                for i in 0..<min(vectorDimension, vectorDouble.count) {
                    accumVector[i] += Float(vectorDouble[i])
                }
                count += 1.0
            }
        }
        
        if count > 0 {
            for i in 0..<vectorDimension {
                accumVector[i] /= count
            }
        }
        
        return VectorMath.normalize(accumVector)
    }

    public func embed(batch: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in batch {
            results.append(try await embed(text: text))
        }
        return results
    }

    // MARK: - LLMProvider Implementation (Apple Foundation Model / Guided Generation)

    public func generateStructuredOutput<T: Decodable & Sendable>(
        prompt: String,
        responseSchema: T.Type
    ) async throws -> T {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryFoundationProviderError.invalidStructuredResponse
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw MemoryFoundationProviderError.modelUnavailable
            }
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: "Return only valid JSON matching the requested Decodable type. Do not add Markdown fences or commentary. Requested type: \(String(reflecting: responseSchema))"
            )
            let response = try await session.respond(to: prompt)
            guard let data = Self.jsonData(from: response.content) else {
                throw MemoryFoundationProviderError.invalidStructuredResponse
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MemoryFoundationProviderError.invalidStructuredResponse
            }
        }
        #endif

        throw MemoryFoundationProviderError.modelUnavailable
    }

    private static func jsonData(from response: String) -> Data? {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = String(value.drop(while: { $0 != "\n" })).trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = value.range(of: "```") {
                value = String(value[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let first = value.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let last = value.lastIndex(where: { $0 == "}" || $0 == "]" }),
              first <= last else { return nil }
        return Data(value[first...last].utf8)
    }
}
