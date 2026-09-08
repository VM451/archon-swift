import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@FoundationModels.Generable
public struct ResearchArguments: Sendable, Codable {
    public var topic: String
    public var maxRounds: Int?
    public var maxDocuments: Int?

    public init(topic: String, maxRounds: Int? = nil, maxDocuments: Int? = nil) {
        self.topic = topic
        self.maxRounds = maxRounds
        self.maxDocuments = maxDocuments
    }
}
#else
public struct ResearchArguments: Sendable, Codable {
    public var topic: String
    public var maxRounds: Int?
    public var maxDocuments: Int?

    public init(topic: String, maxRounds: Int? = nil, maxDocuments: Int? = nil) {
        self.topic = topic
        self.maxRounds = maxRounds
        self.maxDocuments = maxDocuments
    }
}
#endif

/// High-level multi-step autonomous research tool coordinating search, retrieval, and citation verification.
public struct ResearchTool: Tool, Sendable {
    public let name = "deep_research"
    public let description = "Performs bounded autonomous multi-step research on a topic, returning structured findings with verified citations."
    public let coordinator: ResearchCoordinator

    public init(coordinator: ResearchCoordinator) {
        self.coordinator = coordinator
    }

    public init(
        searxngClient: SearXNGClient,
        retrievalRouter: RetrievalRouter,
        options: ResearchOptions = ResearchOptions()
    ) {
        self.coordinator = ResearchCoordinator(
            searxngClient: searxngClient,
            retrievalRouter: retrievalRouter,
            options: options
        )
    }

    /// Primary structured execution entry point.
    public func execute(topic: String, maxRounds: Int? = nil, maxDocuments: Int? = nil) async throws -> String {
        let report = try await coordinator.research(topic: topic)
        var lines: [String] = [
            "# Research Report: \(report.query)",
            "",
            "## Summary",
            report.summary,
            "",
            "## Key Findings"
        ]

        for section in report.sections {
            lines.append("### \(section.heading)")
            lines.append(section.content)
            lines.append("")
        }

        if !report.citations.isEmpty {
            lines.append("## Verified Citations")
            for (idx, citation) in report.citations.enumerated() {
                let title = citation.title ?? "Source"
                lines.append("[\(idx + 1)] \(title) - \(citation.url.absoluteString)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Invokes the tool using a JSON string.
    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let topic = json["topic"] as? String ?? json["query"] as? String else {
            throw SearchError.extraction(reason: "deep_research requires a 'topic' or 'query' string parameter.")
        }
        let maxRounds = json["maxRounds"] as? Int
        let maxDocuments = json["maxDocuments"] as? Int
        return try await execute(topic: topic, maxRounds: maxRounds, maxDocuments: maxDocuments)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
extension ResearchTool: FoundationModels.Tool {
    public typealias Arguments = ResearchArguments
    public typealias Output = String

    public func call(arguments: ResearchArguments) async throws -> String {
        try await execute(
            topic: arguments.topic,
            maxRounds: arguments.maxRounds,
            maxDocuments: arguments.maxDocuments
        )
    }
}
#endif
