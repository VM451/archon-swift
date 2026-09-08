import Foundation
import Observation

/// ViewModel driving the conversational search and research interface.
@Observable
@MainActor
public final class ArchonChatViewModel {
    public var messages: [ArchonChatMessage] = []
    public var inputText: String = ""
    public var mode: SearchComposerMode = .standard
    public var isSearching: Bool = false
    public var errorMessage: String?

    private let client: ArchonSearchClient

    public init(client: ArchonSearchClient) {
        self.client = client
    }

    /// Submits the current query and dispatches either standard search grounding or deep research.
    public func sendQuery() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }

        inputText = ""
        errorMessage = nil
        isSearching = true

        let userMsg = ArchonChatMessage(role: .user, content: query)
        messages.append(userMsg)

        do {
            switch mode {
            case .standard:
                let result = try await client.ask(query: query)
                let assistantMsg = ArchonChatMessage(
                    role: .assistant,
                    content: result.context,
                    citations: result.citations
                )
                messages.append(assistantMsg)

            case .deepResearch:
                let report = try await client.research(topic: query)
                let content = report.summary.isEmpty
                    ? report.sections.map { "### \($0.heading)\n\($0.content)" }.joined(separator: "\n\n")
                    : report.summary
                let assistantMsg = ArchonChatMessage(
                    role: .assistant,
                    content: content,
                    citations: report.citations
                )
                messages.append(assistantMsg)
            }
        } catch {
            errorMessage = error.localizedDescription
            let errorMsg = ArchonChatMessage(
                role: .assistant,
                content: "Error performing search: \(error.localizedDescription)"
            )
            messages.append(errorMsg)
        }

        isSearching = false
    }
}
