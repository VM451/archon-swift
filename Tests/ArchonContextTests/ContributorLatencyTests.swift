import Foundation
import Testing
import ArchonContext

private struct LatencyContributor: ContextContributor {
    let id: String
    let content: String
    let delay: Duration

    func makeContextFragment() async throws -> ContextFragment {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return ContextFragment(id: id, source: id, content: content, priority: 1)
    }
}

struct ContributorLatencyTests {
    @Test("Non-positive latency policies are rejected")
    func invalidPolicy() {
        #expect(throws: ContributorLatencyError.invalidPolicy) {
            try ContributorLatencyPolicy(perContributorTimeout: .zero)
        }
        #expect(throws: ContributorLatencyError.invalidPolicy) {
            try ContributorLatencyPolicy(perContributorTimeout: .seconds(-1))
        }
        #expect(ContributorLatencyError.invalidPolicy.errorDescription?.contains("positive") == true)
    }

    @Test("Slow contributor fails closed with a typed timeout")
    func timeoutFailsClosed() async throws {
        let builder = ContextBuilder(contributors: [
            LatencyContributor(id: "fast", content: "ok", delay: .zero),
            LatencyContributor(id: "slow", content: "late", delay: .seconds(30))
        ])
        let policy = try ContributorLatencyPolicy(perContributorTimeout: .milliseconds(50))
        do {
            _ = try await builder.snapshot(latencyPolicy: policy)
            Issue.record("Timed-out contributor must fail the snapshot.")
        } catch let error as ContributorLatencyError {
            #expect(error == .contributorTimeout(id: "slow"))
            #expect(error.errorDescription?.contains("slow") == true)
        }
    }

    @Test("Generous budgets preserve deterministic ordering")
    func orderingPreserved() async throws {
        let builder = ContextBuilder(contributors: [
            LatencyContributor(id: "zeta", content: "z", delay: .milliseconds(20)),
            LatencyContributor(id: "alpha", content: "a", delay: .zero)
        ])
        let policy = try ContributorLatencyPolicy(perContributorTimeout: .seconds(5))
        let snapshot = try await builder.snapshot(latencyPolicy: policy)
        #expect(snapshot.fragments.map(\.id) == ["alpha", "zeta"])
    }

    @Test("Latency policy composes with summarization fallback")
    func composesWithSummarization() async throws {
        struct IdentitySummarizer: ContextSummarizer {
            func summarize(_ fragments: [ContextFragment], budget: ContextBudget) async throws -> [ContextFragment] {
                fragments
            }
        }
        let builder = ContextBuilder(contributors: [
            LatencyContributor(id: "a", content: "hello", delay: .zero)
        ])
        let policy = try ContributorLatencyPolicy(perContributorTimeout: .seconds(5))
        let snapshot = try await builder.summarizedSnapshot(
            summarizer: IdentitySummarizer(),
            latencyPolicy: policy
        )
        #expect(snapshot.fragments.map(\.id) == ["a"])
    }
}
