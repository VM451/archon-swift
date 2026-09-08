import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@FoundationModels.Generable
public struct WebSearchArguments: Sendable, Codable {
    public var query: String
    public var maxResults: Int?

    public init(query: String, maxResults: Int? = nil) {
        self.query = query
        self.maxResults = maxResults
    }
}
#else
public struct WebSearchArguments: Sendable, Codable {
    public var query: String
    public var maxResults: Int?

    public init(query: String, maxResults: Int? = nil) {
        self.query = query
        self.maxResults = maxResults
    }
}
#endif

/// High-level web search tool providing structured query discovery across public sources.
public struct WebSearchTool: Tool, Sendable {
    public let name = "web_search"
    public let description = "Performs web searches via SearXNG or native search engines returning ranked titles, URLs, and snippets."
    public let client: any SearchEngine

    public init() {
        self.client = DuckDuckGoSearchEngine()
    }

    public init(client: any SearchEngine) {
        self.client = client
    }

    public init(endpoint: URL? = nil) {
        if let endpoint {
            self.client = SearXNGClient(endpoint: endpoint)
        } else {
            self.client = DuckDuckGoSearchEngine()
        }
    }

    /// Primary structured execution entry point.
    public func execute(query: String, maxResults: Int? = nil) async throws -> String {
        let results = try await client.search(query)
        let limit = max(1, min(maxResults ?? 5, 20))
        let trimmed = Array(results.prefix(limit))
        guard !trimmed.isEmpty else {
            return "No search results found for '\(query)'."
        }
        return trimmed.enumerated().map { idx, r in
            "[\(idx + 1)] \(r.title)\nURL: \(r.url.absoluteString)\nSnippet: \(r.snippet)"
        }.joined(separator: "\n\n")
    }

    /// Invokes the tool using a JSON string.
    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let query = json["query"] as? String else {
            throw SearchError.extraction(reason: "web_search requires a 'query' string parameter.")
        }
        let maxResults = json["maxResults"] as? Int
        return try await execute(query: query, maxResults: maxResults)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
extension WebSearchTool: FoundationModels.Tool {
    public typealias Arguments = WebSearchArguments
    public typealias Output = String

    public func call(arguments: WebSearchArguments) async throws -> String {
        try await execute(query: arguments.query, maxResults: arguments.maxResults)
    }
}
#endif
