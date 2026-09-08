import Foundation
import os

/// Composite search engine that attempts queries using a primary engine,
/// cleanly falling back to a secondary engine if the primary is unavailable or fails.
public actor CompositeSearchEngine: SearchEngine {
    public let primary: (any SearchEngine)?
    public let fallback: any SearchEngine
    private let logger = Logger(subsystem: "com.archon.search", category: "CompositeSearchEngine")

    public init(primary: (any SearchEngine)? = nil, fallback: any SearchEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult] {
        if let primary {
            do {
                let results = try await primary.search(query, categories: categories, page: page)
                if !results.isEmpty {
                    return results
                }
            } catch {
                logger.warning("Primary search engine failed for '\(query, privacy: .private)': \(error.localizedDescription). Falling back.")
            }
        }
        return try await fallback.search(query, categories: categories, page: page)
    }

    public func checkHealth() async -> Bool {
        if let primary {
            return await primary.checkHealth()
        }
        return await fallback.checkHealth()
    }
}
