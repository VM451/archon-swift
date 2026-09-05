import Foundation
import ArchonMemory
import ArchonMemoryProxima
import Testing

@Suite("Proxima Vector Index Adapter Tests")
struct ProximaVectorIndexAdapterTests {
    private let configuration = ProximaVectorIndexConfiguration(
        maximumConnections: 4,
        constructionSearchWidth: 16,
        querySearchWidth: 16,
        levelSeed: 42
    )

    @Test("Adapter maps local HNSW results to Archon similarities and filters IDs")
    func mapsAndFilters() async throws {
        let index = try ProximaVectorIndexAdapter(
            dimension: 2,
            configuration: configuration
        )
        let bestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let otherID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        try await index.rebuild([
            ArchonMemory.VectorIndexRecord(id: bestID, vector: [1, 0]),
            ArchonMemory.VectorIndexRecord(id: otherID, vector: [0, 1])
        ])

        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(
                vector: [1, 0],
                limit: 2,
                allowedIDs: [otherID]
            )
        )

        #expect(await index.count == 2)
        #expect(results.map(\.id) == [otherID])
        #expect(results.first?.similarity == 0)
    }

    @Test("Adapter upsert and remove preserve Archon index semantics")
    func upsertAndRemove() async throws {
        let index = try ProximaVectorIndexAdapter(
            dimension: 2,
            configuration: configuration
        )
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

        try await index.upsert(id: id, vector: [1, 0])
        try await index.upsert(id: id, vector: [0, 1])
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: [0, 1], limit: 1)
        )
        #expect(await index.count == 1)
        let removed = try await index.remove(id: id)
        let removedAgain = try await index.remove(id: id)

        #expect(results.first?.id == id)
        #expect(removed)
        #expect(!removedAgain)
        #expect(await index.count == 0)
    }

    @Test("Adapter preserves the previous index when rebuild validation fails")
    func rebuildIsAtomic() async throws {
        let index = try ProximaVectorIndexAdapter(
            dimension: 2,
            configuration: configuration
        )
        let stableID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let duplicateID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        try await index.upsert(id: stableID, vector: [1, 0])

        await #expect(throws: ArchonMemory.VectorIndexError.duplicateID(duplicateID)) {
            try await index.rebuild([
                ArchonMemory.VectorIndexRecord(id: duplicateID, vector: [0, 1]),
                ArchonMemory.VectorIndexRecord(id: duplicateID, vector: [1, 1])
            ])
        }

        #expect(await index.count == 1)
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: [1, 0], limit: 1)
        )
        #expect(results.first?.id == stableID)
    }

    @Test("Adapter rejects invalid dimensions and configuration")
    func rejectsInvalidInputs() async throws {
        #expect(throws: ProximaVectorIndexError.invalidDimension(0)) {
            try ProximaVectorIndexAdapter(dimension: 0, configuration: configuration)
        }
        #expect(
            throws: ProximaVectorIndexError.invalidConfiguration(
                "maximumConnections must be at least 2"
            )
        ) {
            try ProximaVectorIndexAdapter(
                dimension: 2,
                configuration: ProximaVectorIndexConfiguration(maximumConnections: 1)
            )
        }
    }

    @Test("Adapter persists and restores a deterministic snapshot")
    func persistsAndRestores() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let source = try ProximaVectorIndexAdapter(dimension: 2, configuration: configuration)
        try await source.upsert(id: id, vector: [1, 0])
        try await source.persist(to: snapshotURL)

        let restored = try ProximaVectorIndexAdapter(dimension: 2, configuration: configuration)
        try await restored.restore(from: snapshotURL)
        let results = try await restored.search(
            ArchonMemory.VectorIndexQuery(vector: [1, 0], limit: 1)
        )

        #expect(await restored.count == 1)
        #expect(results.first?.id == id)
    }
}
