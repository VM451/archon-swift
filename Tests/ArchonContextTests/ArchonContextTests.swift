import Testing
import ArchonContext

private struct TestContributor: ContextContributor {
    let id: String
    let fragment: ContextFragment

    func makeContextFragment() async throws -> ContextFragment { fragment }
}

struct ArchonContextTests {
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
}
