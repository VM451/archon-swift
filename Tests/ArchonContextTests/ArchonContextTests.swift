import Foundation
import Testing
import ArchonContext

private struct TestContributor: ContextContributor {
    let id: String
    let fragment: ContextFragment

    func makeContextFragment() async throws -> ContextFragment { fragment }
}

private struct DelayedContributor: ContextContributor {
    let id: String

    func makeContextFragment() async throws -> ContextFragment {
        try await Task.sleep(for: .seconds(60))
        return ContextFragment(source: id, content: "unreachable")
    }
}

private actor ConcurrencyProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }

    func maximum() -> Int { maximumActiveCount }
}

private struct ProbedContributor: ContextContributor {
    let id: String
    let probe: ConcurrencyProbe

    func makeContextFragment() async throws -> ContextFragment {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(25))
        await probe.leave()
        return ContextFragment(id: id, source: id, content: id)
    }
}

struct ArchonContextTests {
    @Test("ContextBuilder assembles contributors concurrently and preserves order")
    func assemblesConcurrently() async throws {
        let probe = ConcurrencyProbe()
        let builder = ContextBuilder(contributors: [
            ProbedContributor(id: "first", probe: probe),
            ProbedContributor(id: "second", probe: probe)
        ])

        let snapshot = try await builder.snapshot()

        let maximumConcurrency = await probe.maximum()
        #expect(maximumConcurrency == 2)
        #expect(snapshot.fragments.map(\.id) == ["first", "second"])
    }

    @Test("ContextBuilder assembles contributors by priority")
    func assemblesCurrentContext() async throws {
        let builder = ContextBuilder(contributors: [
            TestContributor(id: "memory", fragment: ContextFragment(source: "memory", content: "remembered", priority: 10)),
            TestContributor(id: "app", fragment: ContextFragment(source: "app", content: "current", priority: 20))
        ])

        let snapshot = try await builder.snapshot()

        #expect(snapshot.fragments.count == 2)
        #expect(snapshot.assembledText.hasPrefix("[app]"))
        #expect(snapshot.assembledText.contains("[memory]"))
    }

    @Test("ContextBuilder orders equal priorities deterministically and applies a byte budget")
    func deterministicBudget() async throws {
        let builder = ContextBuilder(contributors: [
            TestContributor(
                id: "zeta",
                fragment: ContextFragment(id: "zeta", source: "zeta", content: "ignored", priority: 10)
            ),
            TestContributor(
                id: "alpha",
                fragment: ContextFragment(id: "alpha", source: "alpha", content: "abcdefgh", priority: 10)
            )
        ])
        let budget = try ContextBudget(maxUTF8Bytes: 12)

        let snapshot = try await builder.snapshot(budget: budget)

        #expect(snapshot.fragments.map(\.id) == ["alpha"])
        #expect(snapshot.assembledText == "[alpha]\nabcd")
        #expect(snapshot.assembledText.utf8.count <= 12)
    }

    @Test("ContextSnapshot decoding preserves deterministic fragment order")
    func decodingIsDeterministic() throws {
        let snapshot = ContextSnapshot(fragments: [
            ContextFragment(id: "zeta", source: "zeta", content: "z", priority: 1),
            ContextFragment(id: "alpha", source: "alpha", content: "a", priority: 1)
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ContextSnapshot.self, from: data)

        #expect(decoded.fragments.map(\.id) == ["alpha", "zeta"])
    }

    @Test("ContextBuilder rejects negative budgets")
    func invalidBudget() {
        #expect(throws: ContextBuilderError.invalidBudget) {
            try ContextBudget(maxUTF8Bytes: -1)
        }
        #expect(throws: ContextBuilderError.invalidBudget) {
            try ContextBudget(maxTokens: -1)
        }
    }

    @Test("ContextBuilder preserves provenance and applies token budgets")
    func tokenBudgetAndProvenance() async throws {
        let builder = ContextBuilder(contributors: [
            TestContributor(
                id: "memory",
                fragment: ContextFragment(
                    source: "memory",
                    content: "abcdefghijk",
                    priority: 10,
                    provenance: "memory://1",
                    trust: .trusted
                )
            )
        ])

        let snapshot = try await builder.snapshot(budget: try ContextBudget(maxTokens: 4))

        #expect(snapshot.fragments.first?.provenance == "memory://1")
        #expect(snapshot.fragments.first?.trust == .trusted)
        #expect(snapshot.fragments.first?.metadata["archon.truncated"] == "true")
        #expect(snapshot.fragments.first.map { UTF8ContextTokenEstimator().estimateTokens($0.content) } ?? 0 <= 4)
    }

    @Test("ContextBuilder propagates task cancellation")
    func cancellation() async {
        let builder = ContextBuilder(contributors: [
            DelayedContributor(id: "delayed")
        ])
        let task = Task {
            try await builder.snapshot()
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected context assembly to be cancelled.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }
}
