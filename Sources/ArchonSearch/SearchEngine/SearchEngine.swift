import Foundation

/// Defines an interface for on-device and remote search engine backends.
public protocol SearchEngine: Sendable {
    func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult]
    func checkHealth() async -> Bool
}

public extension SearchEngine {
    /// Default convenience search without category filtering or explicit page index.
    func search(_ query: String) async throws -> [SearchResult] {
        try await search(query, categories: nil, page: 1)
    }
}
