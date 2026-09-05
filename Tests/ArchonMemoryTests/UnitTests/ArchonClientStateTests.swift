import Foundation
import Testing
@testable import ArchonMemory

struct ArchonClientStateTests {
    @Test("ArchonMemory defaults keep CloudKit and Spotlight opt-in")
    func safeDefaults() {
        let config = ArchonConfig()
        #expect(config.enableAutoSync == false)
        #expect(config.enableSpotlightIndexing == false)
    }

    @Test("Batch mutations create history and export tombstones")
    func batchHistoryAndExport() async throws {
        let vectorStore = try LocalVectorStore(inMemory: true)
        let graphStore = try LocalGraphStore(inMemory: true)
        let client = try await ArchonClient(config: ArchonConfig(
            llmProvider: MockLLMProvider(),
            embeddingProvider: MockEmbeddingProvider(vectorDimension: 8),
            customVectorStore: vectorStore,
            customGraphStore: graphStore
        ))

        let items = try await client.batchAdd(
            memories: ["first fact", "second fact"],
            userId: "user-1"
        )
        let history = try await client.history(userId: "user-1")
        #expect(history.count == 2)

        try await client.forget(id: items[0].id)
        let exportedData = try await client.export(userId: "user-1")
        let exported = try JSONDecoder().decode(ArchonMemoryExport.self, from: exportedData)
        #expect(exported.memories.contains { $0.id == items[0].id && $0.isDeleted })
        #expect(exported.history.contains { $0.memoryId == items[0].id && $0.action == .delete })
    }
}
