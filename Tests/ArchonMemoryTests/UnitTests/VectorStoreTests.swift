import Testing
import Foundation
@testable import ArchonMemory

@Suite("Local Vector Store Unit Tests")
struct VectorStoreTests {
    
    @Test("Save and fetch MemoryItem by ID")
    func testSaveAndFetch() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let item = MemoryItem(
            memory: "User lives in Bangkok",
            vector: [0.1, 0.2, 0.3],
            userId: "user_bkk"
        )
        
        try await store.save(item: item)
        let fetched = try await store.fetch(id: item.id)
        
        #expect(fetched != nil)
        #expect(fetched?.memory == "User lives in Bangkok")
        #expect(fetched?.userId == "user_bkk")
        #expect(fetched?.vector == [0.1, 0.2, 0.3])
    }

    @Test("Soft delete memory marks item deleted and excludes from search")
    func testSoftDelete() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let item = MemoryItem(memory: "Temporary note", vector: [0.5, 0.5])
        try await store.save(item: item)
        
        try await store.delete(id: item.id)
        
        let activeMemories = try await store.fetchAll(filters: MemoryFilter(includeDeleted: false))
        #expect(!activeMemories.contains(where: { $0.id == item.id }))
        
        let allMemories = try await store.fetchAll(filters: MemoryFilter(includeDeleted: true))
        #expect(allMemories.contains(where: { $0.id == item.id }))
    }

    @Test("Metadata filters apply before pagination")
    func metadataFiltersApplyBeforePagination() async throws {
        let store = try LocalVectorStore(inMemory: true)
        try await store.save(item: MemoryItem(
            memory: "Work note one",
            metadata: ["category": "work"],
            validFrom: Date(timeIntervalSince1970: 1)
        ))
        try await store.save(item: MemoryItem(
            memory: "Personal note",
            metadata: ["category": "personal"],
            validFrom: Date(timeIntervalSince1970: 2)
        ))
        try await store.save(item: MemoryItem(
            memory: "Work note two",
            metadata: ["category": "work"],
            validFrom: Date(timeIntervalSince1970: 3)
        ))

        let results = try await store.fetchAll(
            filters: MemoryFilter(metadata: ["category": "work"], activeAt: nil),
            limit: 1,
            offset: 1
        )

        #expect(results.count == 1)
        #expect(results.first?.memory == "Work note one")
    }

    @Test("Scoped bulk delete preserves another user's FTS search")
    func scopedBulkDeletePreservesOtherUserFTS() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 0, beta: 1)
        try await store.save(item: MemoryItem(
            memory: "Shared project note for user one",
            userId: "user-one",
            validFrom: Date(timeIntervalSince1970: 1)
        ))
        try await store.save(item: MemoryItem(
            memory: "Shared project note for user two",
            userId: "user-two",
            validFrom: Date(timeIntervalSince1970: 2)
        ))

        try await store.deleteAll(userId: "user-one", agentId: nil, runId: nil)

        let results = try await store.search(
            query: "Shared",
            vector: nil,
            limit: 10,
            filters: MemoryFilter(userId: "user-two", activeAt: nil)
        )

        #expect(results.count == 1)
        #expect(results.first?.item.userId == "user-two")
        #expect((results.first?.textRank ?? 0) > 0)
    }

    @Test("Persistent local store recovers records after reopening")
    func persistentStoreReopens() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-memory-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }

        let item = MemoryItem(
            memory: "A durable local memory",
            userId: "recovery-user",
            metadata: ["source": "recovery-test"],
            validFrom: Date(timeIntervalSince1970: 1)
        )
        do {
            let store = try LocalVectorStore(databasePath: databaseURL.path)
            try await store.save(item: item)
        }

        let reopenedStore = try LocalVectorStore(databasePath: databaseURL.path)
        let recovered = try await reopenedStore.fetch(id: item.id)
        #expect(recovered?.id == item.id)
        #expect(recovered?.memory == item.memory)
        #expect(recovered?.hash == item.hash)
        #expect(recovered?.userId == item.userId)
        #expect(recovered?.metadata == item.metadata)
        #expect(recovered?.validFrom == item.validFrom)
        #expect(abs((recovered?.createdAt.timeIntervalSince1970 ?? 0) - item.createdAt.timeIntervalSince1970) < 0.001)
        #expect(abs((recovered?.updatedAt.timeIntervalSince1970 ?? 0) - item.updatedAt.timeIntervalSince1970) < 0.001)
    }

    @Test("Search reflects saves, updates, deletes, and resets immediately")
    func testSearchReflectsMutations() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 1, beta: 0)
        let item = MemoryItem(memory: "Cache fact", vector: [1, 0, 0, 0], userId: "u1")
        try await store.save(item: item)

        let query = VectorMath.normalize([1, 0, 0, 0])
        var results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.map(\.item.id) == [item.id])

        var updated = item
        updated.vector = [0, 0, 0, 1]
        try await store.save(item: updated)
        results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.isEmpty)

        try await store.save(item: item)
        results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.map(\.item.id) == [item.id])

        try await store.delete(id: item.id)
        results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.isEmpty)

        try await store.save(item: item)
        try await store.reset()
        results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.isEmpty)
    }

    @Test("Mixed embedding dimensions search without trapping and score the matching block")
    func mixedDimensionsSearchSafely() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 1, beta: 0)
        let match = MemoryItem(memory: "dim four fact", vector: [1, 0, 0, 0], userId: "u1")
        try await store.save(item: match)
        try await store.save(item: MemoryItem(memory: "dim two fact", vector: [1, 0], userId: "u1"))

        let query = VectorMath.normalize([1, 0, 0, 0])
        let results = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(results.map(\.item.id) == [match.id])
    }

    @Test("Delete keeps block scoring positions consistent across repeated searches")
    func deleteKeepsBlockPositionsConsistent() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 1, beta: 0)
        let basis: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1], [1, 1, 0, 0]]
        var items: [MemoryItem] = []
        for (index, vector) in basis.enumerated() {
            let item = MemoryItem(memory: "fact \(index)", vector: vector, userId: "u1")
            items.append(item)
            try await store.save(item: item)
        }
        try await store.delete(id: items[2].id)

        let query = VectorMath.normalize([0, 0, 0, 1])
        let first = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        let second = try await store.search(query: nil, vector: query, limit: 10, filters: MemoryFilter())
        #expect(first.map(\.item.id) == second.map(\.item.id))
        #expect(first.first?.item.id == items[3].id)
        #expect(first.contains(where: { $0.item.id == items[2].id }) == false)
    }
}
