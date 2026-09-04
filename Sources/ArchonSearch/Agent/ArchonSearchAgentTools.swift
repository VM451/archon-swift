import Foundation

/// Defines standard OpenAPI / JSON Schema tool definitions and execution handlers for integrating
/// ArchonSearch seamlessly with ArchonAgent and native Apple Foundation Model tool dispatchers.
public struct ArchonSearchAgentTools: Sendable {

    /// Returns the complete OpenAPI / JSON Schema definitions for all search capabilities as a JSON string.
    public static func toolsJSONSchemaString() -> String {
        """
        [
          {
            "name": "web_search",
            "description": "Performs 100% on-device privacy-first web and local workspace search returning titles, snippets, and ranked URLs.",
            "parameters": {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "Search query keywords or natural language question" },
                "maxResults": { "type": "integer", "description": "Maximum number of search results to return (default: 5)" },
                "source": { "type": "string", "enum": ["duckduckgo", "wikipedia", "localWorkspace", "socialMedia"], "description": "Discovery source (default: 'duckduckgo')" },
                "directoryPath": { "type": "string", "description": "Directory path when source is 'localWorkspace'" },
                "platforms": { "type": "array", "items": { "type": "string", "enum": ["twitter", "reddit", "youtube", "github", "bilibili", "facebook", "instagram", "linkedin", "xiaohongshu", "v2ex"] }, "description": "Platforms when source is 'socialMedia'; omit to search all supported platforms" }
              },
              "required": ["query"]
            }
          },
          {
            "name": "social_media_search",
            "description": "Searches public, indexed pages across Twitter/X, Reddit, YouTube, GitHub, Bilibili, and other supported social/community platforms without API keys or login cookies.",
            "parameters": {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "Topic, keyword, URL, or natural language question" },
                "platforms": { "type": "array", "items": { "type": "string", "enum": ["twitter", "reddit", "youtube", "github", "bilibili", "facebook", "instagram", "linkedin", "xiaohongshu", "v2ex"] }, "description": "Platforms to search; omit to search all supported platforms" },
                "maxResults": { "type": "integer", "description": "Maximum number of results to return (default: 10)" }
              },
              "required": ["query"]
            }
          },
          {
            "name": "web_contents",
            "description": "Scrapes and extracts full text, clean Markdown, and semantic highlights from target web URLs.",
            "parameters": {
              "type": "object",
              "properties": {
                "url": { "type": "string", "description": "Target web or documentation URL to scrape" }
              },
              "required": ["url"]
            }
          },
          {
            "name": "web_deep_research",
            "description": "Collects evidence across multiple web/local research queries with source URLs and highlights. Model-backed synthesis must be supplied separately.",
            "parameters": {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "Primary research topic or inquiry" },
                "subQueries": { "type": "array", "items": { "type": "string" }, "description": "Optional secondary angles to investigate" },
                "maxPages": { "type": "integer", "description": "Maximum pages to collect per query (default: 3)" },
                "source": { "type": "string", "enum": ["duckduckgo", "wikipedia", "localWorkspace", "socialMedia"], "description": "Discovery source (default: 'duckduckgo')" },
                "directoryPath": { "type": "string", "description": "Directory path when source is 'localWorkspace'" },
                "platforms": { "type": "array", "items": { "type": "string" }, "description": "Platforms when source is 'socialMedia'" }
              },
              "required": ["query"]
            }
          }
        ]
        """
    }

    /// Handles tool execution against a live `ArchonSearch` instance.
    public static func handleToolCall(
        search: ArchonSearch,
        toolName: String,
        argumentsJSON: String
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Error: Invalid JSON arguments for tool '\(toolName)'."
        }

        switch toolName {
        case "web_search":
            guard let query = json["query"] as? String else {
                return "Error: Missing 'query' parameter."
            }
            let maxResults = (json["maxResults"] as? Int) ?? 5
            guard (0...50).contains(maxResults) else { return "Error: maxResults must be between 0 and 50." }
            let sourceStr = (json["source"] as? String)?.lowercased() ?? "duckduckgo"
            let directoryPath = (json["directoryPath"] as? String) ?? "."
            let source: DiscoverySource
            switch sourceStr {
            case "wikipedia": source = .wikipedia
            case "localworkspace": source = .localWorkspace(directoryPath: directoryPath)
            case "socialmedia", "social_media", "social":
                source = .socialMedia(platforms: parsePlatforms(json["platforms"]))
            default: source = .duckDuckGo
            }

            let results = try await search.search(query: query, source: source, maxResults: maxResults)
            if results.isEmpty {
                return "No search results found for '\(query)' via \(sourceStr)."
            }
            return results.enumerated().map { index, r in
                formattedResult(index: index, result: r)
            }.joined(separator: "\n\n")

        case "social_media_search":
            guard let query = json["query"] as? String else {
                return "Error: Missing 'query' parameter."
            }
            let maxResults = (json["maxResults"] as? Int) ?? 10
            guard (0...50).contains(maxResults) else { return "Error: maxResults must be between 0 and 50." }
            let platforms = parsePlatforms(json["platforms"])
            let results = try await search.searchSocialMedia(
                query: query,
                platforms: platforms,
                maxResults: maxResults
            )
            if results.isEmpty {
                let names = platforms.map(\.displayName).joined(separator: ", ")
                return "No public indexed results found for '\(query)' via \(names)."
            }
            return results.enumerated().map { index, result in
                formattedResult(index: index, result: result)
            }.joined(separator: "\n\n")

        case "web_contents":
            guard let urlString = json["url"] as? String, let targetURL = URL(string: urlString) else {
                return "Error: Missing or invalid 'url' parameter."
            }
            guard SearchURLPolicy.validate(targetURL) else {
                return "Error: Only public HTTP(S) URLs are supported."
            }
            let results = try await search.contents(for: [targetURL], query: urlString)
            guard let first = results.first else {
                return "Failed to extract contents for '\(urlString)'."
            }
            return "# \(first.title)\nURL: \(first.url.absoluteString)\n\n\(first.markdown)"

        case "web_deep_research":
            guard let query = json["query"] as? String else {
                return "Error: Missing 'query' parameter."
            }
            let subQueries = (json["subQueries"] as? [String]) ?? []
            let maxPages = (json["maxPages"] as? Int) ?? 3
            guard (1...50).contains(maxPages) else {
                return "Error: maxPages must be between 1 and 50."
            }

            let sourceString = (json["source"] as? String)?.lowercased() ?? "duckduckgo"
            let directoryPath = (json["directoryPath"] as? String) ?? "."
            let source: DiscoverySource
            switch sourceString {
            case "wikipedia": source = .wikipedia
            case "localworkspace": source = .localWorkspace(directoryPath: directoryPath)
            case "socialmedia", "social_media", "social":
                source = .socialMedia(platforms: parsePlatforms(json["platforms"]))
            default: source = .duckDuckGo
            }

            let queries = Array(([query] + subQueries).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(20))
            var seenURLs = Set<URL>()
            var evidence: [(query: String, result: SearchResult)] = []

            for researchQuery in queries {
                try Task.checkCancellation()
                let results = try await search.search(
                    query: researchQuery,
                    source: source,
                    maxResults: maxPages,
                    livecrawl: .fast
                )
                for result in results where seenURLs.insert(result.url).inserted {
                    evidence.append((query: researchQuery, result: result))
                }
            }

            guard !evidence.isEmpty else {
                return "No verified research evidence found for '\(query)'."
            }

            let sourceLines = evidence.enumerated().map { index, item in
                let highlights = item.result.highlights.isEmpty
                    ? item.result.snippet
                    : item.result.highlights.joined(separator: " | ")
                return "[\(index + 1)] \(item.result.title)\nQuery: \(item.query)\nURL: \(item.result.url.absoluteString)\nEvidence: \(highlights)"
            }.joined(separator: "\n\n")
            let subInfo = subQueries.isEmpty ? "" : "\nQueries explored: " + queries.joined(separator: ", ")
            return """
            # Deep Research Findings for: "\(query)"\(subInfo)

            ## Verified Evidence
            \(sourceLines)

            ## Synthesis
            Evidence collection completed. No model-backed synthesis was claimed or fabricated; provide an explicit structured-generation adapter when a synthesized answer is required.
            """

        default:
            return "Error: Unsupported tool '\(toolName)'."
        }
    }

    private static func parsePlatforms(_ value: Any?) -> [SocialPlatform] {
        guard let identifiers = value as? [String] else {
            return SocialPlatform.allCases
        }

        let platforms = identifiers.compactMap(SocialPlatform.init(identifier:))
        return platforms.isEmpty ? SocialPlatform.allCases : platforms
    }

    private static func formattedResult(index: Int, result: SearchResult) -> String {
        let platform = SocialPlatform.platform(for: result.url)?.displayName ?? "Web"
        return "[\(index + 1)] [\(platform)] \(result.title)\nURL: \(result.url.absoluteString)\nSnippet: \(result.snippet)"
    }
}
