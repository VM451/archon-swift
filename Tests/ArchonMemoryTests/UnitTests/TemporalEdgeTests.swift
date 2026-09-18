import Testing
import Foundation
@testable import ArchonMemory

@Suite("Temporal Supersession and Invalidation Edges")
struct TemporalEdgeTests {
    private func makeExtractor(
        store: LocalVectorStore,
        operations: [MemoryOperation]
    ) -> MemoryExtractor {
        MemoryExtractor(
            vectorStore: store,
            embeddingProvider: MockEmbeddingProvider(vectorDimension: 8),
            llmProvider: MockLLMProvider(mockOperations: operations)
        )
    }

    private func updateOp(id: UUID, memory: String) -> MemoryOperation {
        MemoryOperation(event: .update, memory: memory, id: id.uuidString)
    }

    private func extract(_ extractor: MemoryExtractor) async throws -> MemoryChangeset {
        try await extractor.extractAndApply(
            messages: [Message(role: .user, content: "update my preferences")],
            userId: "temporal-user"
        )
    }

    @Test("Updating a superseded record extends the chain without forking")
    func updateSupersededChainsToHead() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let v1 = MemoryItem(memory: "User likes tea", vector: [0.1, 0.2])
        try await store.save(item: v1)

        let first = makeExtractor(store: store, operations: [updateOp(id: v1.id, memory: "User likes coffee")])
        let firstResult = try await extract(first)
        #expect(firstResult.skipped.isEmpty)
        let v2id = try #require(firstResult.affectedItems.first?.id)

        // Targeting the superseded v1 must resolve to the v2 head.
        let second = makeExtractor(store: store, operations: [updateOp(id: v1.id, memory: "User likes espresso")])
        let secondResult = try await extract(second)
        #expect(secondResult.skipped.isEmpty)
        let v3id = try #require(secondResult.affectedItems.first?.id)

        let reloadedV1 = try #require(try await store.fetch(id: v1.id))
        let reloadedV2 = try #require(try await store.fetch(id: v2id))
        let reloadedV3 = try #require(try await store.fetch(id: v3id))
        // No fork: v1 still points at v2, and v2 now points at v3.
        #expect(reloadedV1.supersededById == v2id)
        #expect(reloadedV2.supersededById == v3id)
        #expect(reloadedV3.supersededById == nil)
        #expect(reloadedV3.version == reloadedV2.version + 1)
        #expect(reloadedV3.memory == "User likes espresso")

        let resolved = try await second.resolveSupersessionHead(for: v1.id)
        #expect(resolved.id == v3id)
    }

    @Test("Updating a deleted record is a typed skip with history intact")
    func updateDeletedIsTypedSkip() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let item = MemoryItem(memory: "Ephemeral note", vector: [0.1, 0.2])
        try await store.save(item: item)
        try await store.delete(id: item.id)

        let extractor = makeExtractor(store: store, operations: [updateOp(id: item.id, memory: "Revived note")])
        let result = try await extract(extractor)
        #expect(result.changes.isEmpty)
        #expect(result.affectedItems.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .targetDeleted(item.id))
        #expect(try await store.fetchHistory(memoryId: nil, userId: nil).isEmpty)
    }

    @Test("Updating a missing record is a typed skip with history intact")
    func updateMissingIsTypedSkip() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let missing = UUID()
        let extractor = makeExtractor(store: store, operations: [updateOp(id: missing, memory: "Ghost update")])
        let result = try await extract(extractor)
        #expect(result.changes.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .targetMissing(missing))
        #expect(try await store.fetchHistory(memoryId: nil, userId: nil).isEmpty)

        await #expect(throws: ArchonMemoryError.supersessionTargetInvalid(missing)) {
            try await extractor.resolveSupersessionHead(for: missing)
        }
    }

    @Test("Updating an expired head is a typed skip with history intact")
    func updateExpiredIsTypedSkip() async throws {
        let store = try LocalVectorStore(inMemory: true)
        var item = MemoryItem(memory: "Old address", vector: [0.1, 0.2])
        item.validTo = Date(timeIntervalSince1970: 1_000)
        try await store.save(item: item)

        let extractor = makeExtractor(store: store, operations: [updateOp(id: item.id, memory: "New address")])
        let result = try await extract(extractor)
        #expect(result.changes.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .targetExpired(item.id))
        #expect(try await store.fetchHistory(memoryId: nil, userId: nil).isEmpty)
    }

    @Test("Unparsable update targets are recorded as invalid")
    func updateInvalidTargetIDIsRecorded() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let extractor = makeExtractor(
            store: store,
            operations: [MemoryOperation(event: .update, memory: "Nowhere", id: "not-a-uuid")]
        )
        let result = try await extract(extractor)
        #expect(result.changes.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .invalidTargetID("not-a-uuid"))
    }

    @Test("A record expiring exactly at activeAt is excluded")
    func validToBoundaryIsExcluded() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let boundary = Date(timeIntervalSince1970: 5_000)
        var item = MemoryItem(
            memory: "Boundary fact",
            vector: [0.1, 0.2],
            validFrom: Date(timeIntervalSince1970: 1_000)
        )
        item.validTo = boundary
        try await store.save(item: item)

        let atBoundary = try await store.fetchAll(filters: MemoryFilter(activeAt: boundary))
        #expect(!atBoundary.contains(where: { $0.id == item.id }))

        let justBefore = try await store.fetchAll(
            filters: MemoryFilter(activeAt: boundary.addingTimeInterval(-1))
        )
        #expect(justBefore.contains(where: { $0.id == item.id }))

        let atValidFrom = try await store.fetchAll(
            filters: MemoryFilter(activeAt: Date(timeIntervalSince1970: 1_000))
        )
        #expect(atValidFrom.contains(where: { $0.id == item.id }))
    }

    @Test("Dangling supersededById is rejected with a typed error")
    func danglingSupersededByIdRejected() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let dangling = UUID()
        var item = MemoryItem(memory: "Orphaned version", vector: [0.1, 0.2])
        item.validTo = Date()
        item.supersededById = dangling
        try await store.save(item: item)

        let extractor = makeExtractor(store: store, operations: [updateOp(id: item.id, memory: "Next version")])
        await #expect(throws: ArchonMemoryError.supersessionChainBroken(dangling)) {
            try await extractor.resolveSupersessionHead(for: item.id)
        }
        let result = try await extract(extractor)
        #expect(result.changes.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .supersessionChainBroken(dangling))
        #expect(try await store.fetchHistory(memoryId: nil, userId: nil).isEmpty)
    }

    @Test("A supersession cycle is rejected as a broken chain")
    func supersessionCycleRejected() async throws {
        let store = try LocalVectorStore(inMemory: true)
        var first = MemoryItem(memory: "Cycle A", vector: [0.1, 0.2])
        var second = MemoryItem(memory: "Cycle B", vector: [0.3, 0.4])
        first.supersededById = second.id
        second.supersededById = first.id
        try await store.save(item: first)
        try await store.save(item: second)

        let extractor = makeExtractor(store: store, operations: [])
        await #expect(throws: ArchonMemoryError.self) {
            try await extractor.resolveSupersessionHead(for: first.id)
        }
    }

    @Test("Timeless queries still return the full supersession chain")
    func timelessQueryReturnsFullChain() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let v1 = MemoryItem(memory: "User lives in Bangkok", vector: [0.1, 0.2])
        try await store.save(item: v1)
        let extractor = makeExtractor(store: store, operations: [updateOp(id: v1.id, memory: "User lives in Chiang Mai")])
        let result = try await extract(extractor)
        #expect(result.skipped.isEmpty)
        let v2id = try #require(result.affectedItems.first?.id)

        let timeless = try await store.fetchAll(filters: MemoryFilter(activeAt: nil))
        let timelessIDs = Set(timeless.map(\.id))
        #expect(timelessIDs.contains(v1.id))
        #expect(timelessIDs.contains(v2id))

        let current = try await store.fetchAll(filters: MemoryFilter(activeAt: Date()))
        #expect(!current.contains(where: { $0.id == v1.id }))
        #expect(current.contains(where: { $0.id == v2id }))
    }

    @Test("Skip reasons round-trip through Codable with the changeset")
    func changesetSkipsRoundTrip() throws {
        let id = UUID()
        let changeset = MemoryChangeset(
            changes: [],
            affectedItems: [],
            skipped: [
                MemoryExtractionSkip(
                    operation: MemoryOperation(event: .update, memory: "x", id: id.uuidString),
                    reason: .targetDeleted(id)
                ),
                MemoryExtractionSkip(
                    operation: MemoryOperation(event: .update, memory: "y", id: nil),
                    reason: .invalidTargetID(nil)
                ),
            ]
        )
        let data = try JSONEncoder().encode(changeset)
        let decoded = try JSONDecoder().decode(MemoryChangeset.self, from: data)
        #expect(decoded == changeset)

        // Payloads written before skips existed still decode.
        let legacy = try JSONEncoder().encode(["changes": [], "affectedItems": []] as [String: [MemoryItem]])
        let legacyDecoded = try JSONDecoder().decode(MemoryChangeset.self, from: legacy)
        #expect(legacyDecoded.skipped.isEmpty)
    }
}
