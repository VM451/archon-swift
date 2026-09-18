import Foundation
import Testing
import ArchonContext

private struct SummaryContributor: ContextContributor {
    let id: String
    let fragment: ContextFragment

    func makeContextFragment() async throws -> ContextFragment { fragment }
}

private struct FakeSummarizer: ContextSummarizer {
    func summarize(_ fragments: [ContextFragment], budget: ContextBudget) async throws -> [ContextFragment] {
        fragments.map {
            ContextFragment(
                id: $0.id,
                source: "summary:\($0.source)",
                content: "summary of \($0.content)",
                priority: $0.priority,
                metadata: ["archon.summarized": "true"],
                provenance: $0.provenance,
                trust: $0.trust
            )
        }
    }
}

private struct UnavailableSummarizer: ContextSummarizer {
    func summarize(_ fragments: [ContextFragment], budget: ContextBudget) async throws -> [ContextFragment] {
        throw ContextSummarizationError.unavailable("model not loaded")
    }
}

private struct SlowSummarizer: ContextSummarizer {
    func summarize(_ fragments: [ContextFragment], budget: ContextBudget) async throws -> [ContextFragment] {
        try await Task.sleep(for: .seconds(60))
        return fragments
    }
}

struct SummarizationTests {
    private func builder() -> ContextBuilder {
        ContextBuilder(contributors: [
            SummaryContributor(
                id: "memory",
                fragment: ContextFragment(
                    id: "memory", source: "memory", content: "remembered facts",
                    priority: 10, provenance: "memory://1", trust: .trusted
                )
            ),
            SummaryContributor(
                id: "app",
                fragment: ContextFragment(
                    id: "app", source: "app", content: "current screen",
                    priority: 20, provenance: "app://now", trust: .unknown
                )
            )
        ])
    }

    @Test("Host summarizer output preserves provenance, trust, and order")
    func hostSummarizer() async throws {
        let snapshot = try await builder().summarizedSnapshot(summarizer: FakeSummarizer())
        #expect(snapshot.fragments.count == 2)
        #expect(snapshot.fragments.map(\.id) == ["app", "memory"])
        #expect(snapshot.fragments.allSatisfy { $0.metadata["archon.summarized"] == "true" })
        #expect(snapshot.fragments.first?.provenance == "app://now")
        #expect(snapshot.fragments.first?.trust == .unknown)
        #expect(snapshot.fragments.last?.provenance == "memory://1")
        #expect(snapshot.fragments.last?.trust == .trusted)
        #expect(snapshot.fragments.first?.content == "summary of current screen")
    }

    @Test("Nil summarizer falls back to truncation")
    func nilSummarizerFallsBack() async throws {
        let snapshot = try await builder().summarizedSnapshot(
            budget: try ContextBudget(maxUTF8Bytes: 12),
            summarizer: nil
        )
        #expect(snapshot.fragments.map(\.id) == ["app"])
        #expect(snapshot.assembledText.utf8.count <= 12)
    }

    @Test("Throwing summarizer falls back or rethrows by flag")
    func throwingSummarizer() async throws {
        let fallback = try await builder().summarizedSnapshot(
            budget: try ContextBudget(maxFragments: 1),
            summarizer: UnavailableSummarizer(),
            fallbackToTruncation: true
        )
        #expect(fallback.fragments.count == 1)

        do {
            _ = try await builder().summarizedSnapshot(
                summarizer: UnavailableSummarizer(),
                fallbackToTruncation: false
            )
            Issue.record("Unavailable summarizer must rethrow without fallback.")
        } catch let error as ContextSummarizationError {
            #expect(error == .unavailable("model not loaded"))
            #expect(error.errorDescription?.contains("model not loaded") == true)
        }
    }

    @Test("Summarization propagates task cancellation")
    func cancellation() async {
        let builder = builder()
        let task = Task {
            try await builder.summarizedSnapshot(summarizer: SlowSummarizer())
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled summarization must throw.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }
}
