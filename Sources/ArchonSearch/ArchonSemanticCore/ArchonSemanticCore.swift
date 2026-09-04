import Foundation
import NaturalLanguage

/// Protocol for structured data models that can be extracted by ArchonSearch.
public protocol ArchonGenerable: Codable, Sendable {}

public typealias Generable = ArchonGenerable

public enum ArchonSemanticCoreError: Error, LocalizedError, Equatable, Sendable {
    case structuredExtractionUnavailable

    public var errorDescription: String? {
        switch self {
        case .structuredExtractionUnavailable:
            return "Structured extraction requires an injected model/runtime adapter."
        }
    }
}

/// Host-provided structured generation boundary. The handler returns JSON that
/// the caller's `ArchonGenerable` type can decode; ArchonSearch never invents
/// field values when no model is configured.
public typealias StructuredExtractionHandler = @Sendable (
    _ sourceText: String,
    _ query: String,
    _ requestedType: String
) async throws -> Data

/// A native vector embedding utility utilizing Apple's Natural Language sentence embeddings.
public struct FoundationEmbedding: Sendable {
    public init() {}
    
    /// Generates a vector embedding for the given text.
    public func vector(for text: String) async throws -> [Double] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw NSError(domain: "FoundationEmbedding", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize native English sentence embedding model."])
        }
        
        guard let vec = embedding.vector(for: text) else {
            throw NSError(domain: "FoundationEmbedding", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate embedding vector for input text."])
        }
        
        return vec
    }
    
    /// Calculates the cosine similarity between two high-dimensional vectors.
    public func similarity(_ vec1: [Double], _ vec2: [Double]) -> Double {
        guard vec1.count == vec2.count, !vec1.isEmpty else { return 0.0 }
        
        let dotProduct = zip(vec1, vec2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vec1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vec2.map { $0 * $0 }.reduce(0, +))
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }
        return dotProduct / (magnitude1 * magnitude2)
    }
}

/// Orchestrates local vector similarity ranking and structured LLM extraction.
public struct ArchonSemanticCore: Sendable {
    private let embedding = FoundationEmbedding()
    private let structuredExtractionHandler: StructuredExtractionHandler?
    
    public init(structuredExtractionHandler: StructuredExtractionHandler? = nil) {
        self.structuredExtractionHandler = structuredExtractionHandler
    }
    
    /// Ranks text chunks by semantic similarity to the query and return a concatenated context.
    public func extractRelevantContext(from text: String, query: String, maxCharacters: Int = 4000) async throws -> String {
        try Task.checkCancellation()
        let queryVector = try await embedding.vector(for: query)
        
        // Split text by paragraphs
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 15 }
        
        var scoredParagraphs = [(text: String, score: Double)]()
        for paragraph in paragraphs {
            try Task.checkCancellation()
            do {
                let vec = try await embedding.vector(for: paragraph)
                let score = embedding.similarity(queryVector, vec)
                scoredParagraphs.append((paragraph, score))
            } catch {
                // Skip paragraph if vector generation fails
            }
        }
        
        // Sort highest similarity score first
        let sorted = scoredParagraphs.sorted { $0.score > $1.score }

        var result = ""
        for item in sorted {
            try Task.checkCancellation()
            if result.count + item.text.count > maxCharacters {
                break
            }
            if !result.isEmpty {
                result += "\n\n"
            }
            result += item.text
        }
        
        return result.isEmpty ? text : result
    }
    
    /// Extracts structured data from text using semantic structural parsing.
    public func extract<T: ArchonGenerable>(from text: String, query: String, as type: T.Type) async throws -> T {
        guard let structuredExtractionHandler else {
            throw ArchonSemanticCoreError.structuredExtractionUnavailable
        }
        let data = try await structuredExtractionHandler(text, query, String(reflecting: type))
        return try JSONDecoder().decode(type, from: data)
    }
    
    /// Synthesizes inline source citations by mapping extracted fields back to their crawled page context.
    public func matchCitations<T: Codable & Sendable>(
        for extracted: T,
        scrapedPages: [ScrapedPageData]
    ) -> [Citation] {
        var citations = [Citation]()
        var index = 1
        
        guard let data = try? JSONEncoder().encode(extracted),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        
        for (key, val) in json {
            let valStr = String(describing: val).trimmingCharacters(in: .whitespacesAndNewlines)
            guard valStr.count > 4 && valStr != "nil" else { continue }
            
            for page in scrapedPages {
                if page.text.localizedCaseInsensitiveContains(valStr) {
                    let snippet = "Field '\(key)' extracted: ...\(valStr)..."
                    citations.append(Citation(index: index, sourceURLString: page.url.absoluteString, snippet: snippet))
                    index += 1
                    break
                }
            }
        }
        return citations
    }
}

/// Helper data holder containing the URL and text of a scraped page for citation extraction.
public struct ScrapedPageData: Sendable, Codable {
    public let url: URL
    public let text: String
    
    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

/// An extracted citation mapping a specific piece of information back to its source URL.
public struct Citation: Sendable, Codable, Hashable {
    public let index: Int
    public let sourceURLString: String
    public let snippet: String
    
    public init(index: Int, sourceURLString: String, snippet: String) {
        self.index = index
        self.sourceURLString = sourceURLString
        self.snippet = snippet
    }
}
