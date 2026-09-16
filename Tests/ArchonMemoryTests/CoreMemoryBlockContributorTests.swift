import Testing
import Foundation
import ArchonContext
@testable import ArchonMemory

@Suite("Core Memory Block Contributor Tests")
struct CoreMemoryBlockContributorTests {
    private func makeClient() async throws -> ArchonClient {
        let vectorStore = try LocalVectorStore(inMemory: true)
        let graphStore = try LocalGraphStore(inMemory: true)
        let config = ArchonConfig(
            llmProvider: MockLLMProvider(),
            embeddingProvider: MockEmbeddingProvider(vectorDimension: 64),
            customVectorStore: vectorStore,
            customGraphStore: graphStore,
            enableAutoSync: false,
            enableSpotlightIndexing: false
        )
        return try await ArchonClient(config: config)
    }

    @Test("Contributor emits only consented keys in sorted order")
    func testEmitsOnlyConsentedKeysSorted() async throws {
        var blocks = CoreMemoryBlock()
        blocks.update(key: "zeta", value: "last")
        blocks.update(key: "alpha", value: "first")
        blocks.update(key: "secret", value: "never")
        let contributor = CoreMemoryBlockContributor(
            blocks: blocks,
            consent: MemoryBlockConsent(userId: "u1", consentedKeys: ["zeta", "alpha"])
        )

        let fragment = try await contributor.makeContextFragment()
        #expect(contributor.id == "archon.memory.core-blocks")
        #expect(fragment.id == "archon.memory.core-blocks")
        #expect(fragment.source == "archon.memory.core-blocks")
        #expect(fragment.provenance == "archon.memory.core-blocks")
        #expect(fragment.content == "alpha: first\nzeta: last")
        #expect(!fragment.content.contains("secret"))
        #expect(fragment.metadata["archon.memory.keys"] == "alpha,zeta")
        #expect(fragment.metadata["archon.memory.userId"] == "u1")
    }

    @Test("Empty effective consent fails closed with a typed error")
    func testEmptyConsentFailsClosed() async {
        let contributor = CoreMemoryBlockContributor(
            blocks: CoreMemoryBlock(blocks: ["a": "1"]),
            consent: MemoryBlockConsent(consentedKeys: [])
        )
        await #expect(throws: MemoryBlockContributorError.noConsentedContent) {
            try await contributor.makeContextFragment()
        }

        let disjoint = CoreMemoryBlockContributor(
            blocks: CoreMemoryBlock(blocks: ["a": "1"]),
            consent: MemoryBlockConsent(consentedKeys: ["zzz"])
        )
        await #expect(throws: MemoryBlockContributorError.noConsentedContent) {
            try await disjoint.makeContextFragment()
        }
    }

    @Test("Priority and trust propagate to the fragment")
    func testPriorityAndTrustPropagate() async throws {
        let contributor = CoreMemoryBlockContributor(
            blocks: CoreMemoryBlock(blocks: ["a": "1"]),
            consent: MemoryBlockConsent(consentedKeys: ["a"]),
            priority: 250,
            trust: .trusted
        )
        let fragment = try await contributor.makeContextFragment()
        #expect(fragment.priority == 250)
        #expect(fragment.trust == .trusted)
    }

    @Test("Client contributor binds the consented user scope")
    func testClientBindsConsentedScope() async throws {
        let client = try await makeClient()
        try await client.updateCoreBlock(key: "persona", value: "Test pilot", userId: "u1")
        try await client.updateCoreBlock(key: "other", value: "Elsewhere", userId: "u2")

        let contributor = try await client.coreBlockContributor(
            consent: MemoryBlockConsent(userId: "u1", consentedKeys: ["persona", "other"])
        )
        let fragment = try await contributor.makeContextFragment()
        #expect(fragment.content == "persona: Test pilot")
    }

    @Test("Contributor composes with ContextBuilder snapshots")
    func testComposesWithContextBuilder() async throws {
        let contributor = CoreMemoryBlockContributor(
            blocks: CoreMemoryBlock(blocks: ["persona": "Test pilot"]),
            consent: MemoryBlockConsent(consentedKeys: ["persona"])
        )
        let builder = ContextBuilder()
        await builder.register(contributor)
        let snapshot = try await builder.snapshot()

        #expect(snapshot.fragments.count == 1)
        #expect(snapshot.fragments.first?.source == "archon.memory.core-blocks")
        #expect(snapshot.fragments.first?.content == "persona: Test pilot")
    }
}
