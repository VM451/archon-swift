import ArchonMemory
import ArchonMemoryProxima
import Foundation
import Testing

@Suite("Proxima Coverage Tests")
struct ProximaCoverageTests {
    private func makeIndex(dimension: Int = 2) throws -> ProximaVectorIndexAdapter {
        try ProximaVectorIndexAdapter(
            dimension: dimension,
            configuration: ProximaVectorIndexConfiguration(
                maximumConnections: 4,
                constructionSearchWidth: 16,
                querySearchWidth: 16,
                levelSeed: 7
            )
        )
    }

    // MARK: - Common

    @Test("Upsert then search returns best match first")
    func commonSearchOrdering() async throws {
        let index = try makeIndex()
        let best = UUID()
        let other = UUID()
        try await index.rebuild([
            VectorIndexRecord(id: best, vector: [1, 0]),
            VectorIndexRecord(id: other, vector: [0, 1]),
        ])
        let results = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 2))
        #expect(results.count == 2)
        #expect(results.first?.id == best)
        #expect(results[0].similarity >= results[1].similarity)
        #expect(await index.count == 2)
    }

    @Test("Empty rebuild clears the index")
    func commonEmptyRebuild() async throws {
        let index = try makeIndex()
        let id = UUID()
        try await index.upsert(id: id, vector: [1, 0])
        try await index.rebuild([])
        #expect(await index.count == 0)
        let results = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 5))
        #expect(results.isEmpty)
    }

    // MARK: - Edge

    @Test("Limit zero returns empty without error")
    func edgeLimitZero() async throws {
        let index = try makeIndex()
        try await index.upsert(id: UUID(), vector: [1, 0])
        let results = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 0))
        #expect(results.isEmpty)
    }

    @Test("Empty allow-list returns empty")
    func edgeEmptyAllowList() async throws {
        let index = try makeIndex()
        try await index.upsert(id: UUID(), vector: [1, 0])
        let results = try await index.search(
            VectorIndexQuery(vector: [1, 0], limit: 5, allowedIDs: [])
        )
        #expect(results.isEmpty)
    }

    @Test("Removing a missing ID returns false")
    func edgeRemoveMissing() async throws {
        let index = try makeIndex()
        #expect(try await index.remove(id: UUID()) == false)
    }

    @Test("Upsert overwrites the same ID without growing count")
    func edgeUpsertOverwrite() async throws {
        let index = try makeIndex()
        let id = UUID()
        try await index.upsert(id: id, vector: [1, 0])
        try await index.upsert(id: id, vector: [1, 0])
        #expect(await index.count == 1)
    }

    // MARK: - Error / boundary

    @Test("Vector validation errors")
    func errorVectorValidation() async throws {
        let index = try makeIndex()
        let id = UUID()
        await #expect(throws: VectorIndexError.emptyVector) {
            try await index.upsert(id: id, vector: [])
        }
        await #expect(throws: VectorIndexError.invalidDimension(expected: 2, actual: 3)) {
            try await index.upsert(id: id, vector: [1, 2, 3])
        }
        await #expect(throws: VectorIndexError.nonFiniteComponent) {
            try await index.upsert(id: id, vector: [.infinity, 0])
        }
        await #expect(throws: VectorIndexError.nonFiniteComponent) {
            try await index.upsert(id: id, vector: [.nan, 0])
        }
        await #expect(throws: VectorIndexError.emptyVector) {
            _ = try await index.search(VectorIndexQuery(vector: [], limit: 1))
        }
        await #expect(throws: VectorIndexError.invalidDimension(expected: 2, actual: 1)) {
            _ = try await index.search(VectorIndexQuery(vector: [1], limit: 1))
        }
    }

    @Test("Limit boundaries: 500 ok, 501 and negative rejected")
    func boundaryLimits() async throws {
        let index = try makeIndex()
        try await index.upsert(id: UUID(), vector: [1, 0])
        _ = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 500))
        await #expect(throws: VectorIndexError.invalidLimit(501)) {
            _ = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 501))
        }
        await #expect(throws: VectorIndexError.invalidLimit(-1)) {
            _ = try await index.search(VectorIndexQuery(vector: [1, 0], limit: -1))
        }
    }

    @Test("Init rejects bad dimension and config boundaries")
    func errorInitBoundaries() {
        #expect(throws: ProximaVectorIndexError.invalidDimension(0)) {
            try ProximaVectorIndexAdapter(dimension: 0)
        }
        #expect(throws: ProximaVectorIndexError.invalidDimension(-3)) {
            try ProximaVectorIndexAdapter(dimension: -3)
        }
        #expect(throws: ProximaVectorIndexError.self) {
            try ProximaVectorIndexAdapter(
                dimension: 2,
                configuration: ProximaVectorIndexConfiguration(
                    maximumConnections: 1, constructionSearchWidth: 16, querySearchWidth: 16
                )
            )
        }
        #expect(throws: ProximaVectorIndexError.self) {
            try ProximaVectorIndexAdapter(
                dimension: 2,
                configuration: ProximaVectorIndexConfiguration(
                    maximumConnections: 4, constructionSearchWidth: 0, querySearchWidth: 16
                )
            )
        }
        #expect(throws: ProximaVectorIndexError.self) {
            try ProximaVectorIndexAdapter(
                dimension: 2,
                configuration: ProximaVectorIndexConfiguration(
                    maximumConnections: 4, constructionSearchWidth: 16, querySearchWidth: 0
                )
            )
        }
        // Minimum valid boundary: maximumConnections == 2 is accepted.
        #expect(throws: Never.self) {
            _ = try ProximaVectorIndexAdapter(
                dimension: 2,
                configuration: ProximaVectorIndexConfiguration(
                    maximumConnections: 2, constructionSearchWidth: 1, querySearchWidth: 1
                )
            )
        }
    }

    @Test("Rebuild rejects duplicate IDs")
    func errorDuplicateRebuild() async throws {
        let index = try makeIndex()
        let dup = UUID()
        await #expect(throws: VectorIndexError.duplicateID(dup)) {
            try await index.rebuild([
                VectorIndexRecord(id: dup, vector: [1, 0]),
                VectorIndexRecord(id: dup, vector: [0, 1]),
            ])
        }
    }

    @Test("Similarities are clamped to [-1, 1]")
    func boundarySimilarityClamp() async throws {
        let index = try makeIndex()
        let id = UUID()
        try await index.upsert(id: id, vector: [1, 0])
        let results = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 1))
        #expect(results.count == 1)
        #expect(results[0].similarity <= 1)
        #expect(results[0].similarity >= -1)
    }

    @Test("Persist requires a file URL and restore checks dimension")
    func errorPersistence() async throws {
        let index = try makeIndex()
        await #expect(throws: ProximaVectorIndexError.self) {
            try await index.persist(to: URL(string: "https://example.com/snap.json")!)
        }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-missing-\(UUID().uuidString).json")
        await #expect(throws: ProximaVectorIndexError.self) {
            try await index.restore(from: missing)
        }
        await #expect(throws: ProximaVectorIndexError.self) {
            try await index.restore(from: URL(string: "https://example.com/snap.json")!)
        }
        // Dimension mismatch snapshot.
        let other = try ProximaVectorIndexAdapter(
            dimension: 3,
            configuration: ProximaVectorIndexConfiguration(
                maximumConnections: 4, constructionSearchWidth: 16,
                querySearchWidth: 16, levelSeed: 7
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await other.upsert(id: UUID(), vector: [1, 0, 0])
        try await other.persist(to: url)
        await #expect(throws: ProximaVectorIndexError.invalidDimension(3)) {
            try await index.restore(from: url)
        }
    }

    // MARK: - Cancellation

    @Test("Cancelled rebuild throws CancellationError")
    func cancellationRebuild() async throws {
        let index = try makeIndex()
        var records: [VectorIndexRecord] = []
        for _ in 0..<50 {
            records.append(VectorIndexRecord(id: UUID(), vector: [1, 0]))
        }
        let task = Task {
            try await index.rebuild(records)
        }
        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Policy / model contracts (no network, no private API)

    @Test("Extraction and retrieval policies clamp negative bounds")
    func policyClamping() {
        #expect(MemoryExtractionPolicy(maxCandidates: -5).maxCandidates == 0)
        #expect(MemoryRetrievalPolicy(maximumResults: -1).maximumResults == 0)
        #expect(MemoryExtractionPolicy.standard.allowAutomaticDeletion == false)
        #expect(MemoryRetrievalPolicy.standard.includeDeleted == false)
        #expect(MemoryFilter().includeDeleted == false)
    }

    @Test("MemoryItem hash is deterministic and case-insensitive")
    func policyMemoryHash() {
        let a = MemoryItem(memory: "  Hello World ")
        let b = MemoryItem(memory: "hello world")
        #expect(a.hash == b.hash)
        #expect(!a.hash.isEmpty)
    }

    @Test("Error descriptions are present")
    func policyErrorDescriptions() {
        let id = UUID()
        #expect((ArchonMemoryError.memoryNotFound(id) as Error).localizedDescription.contains(id.uuidString))
        #expect((VectorIndexError.emptyVector as Error).localizedDescription.count > 0)
        #expect((VectorIndexError.invalidLimit(501) as Error).localizedDescription.contains("501"))
        #expect(
            (ProximaVectorIndexError.invalidDimension(0) as Error).localizedDescription.contains("0")
        )
        #expect(
            (ProximaVectorIndexError.invalidConfiguration("x") as Error)
                .localizedDescription.contains("x")
        )
        #expect((ProximaVectorIndexError.busy as Error).localizedDescription.count > 0)
    }

    @Test("Configuration and snapshot round-trip through Codable")
    func policyCodableRoundTrip() throws {
        let config = ProximaVectorIndexConfiguration(
            maximumConnections: 4, constructionSearchWidth: 16,
            querySearchWidth: 16, levelSeed: 7
        )
        let configData = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ProximaVectorIndexConfiguration.self, from: configData) == config)
        #expect(ProximaVectorIndexConfiguration.standard.maximumConnections == 16)
        let snapshot = ProximaVectorIndexSnapshot(
            dimension: 2, configuration: config,
            records: [VectorIndexRecord(id: UUID(), vector: [1, 0])]
        )
        let snapData = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ProximaVectorIndexSnapshot.self, from: snapData) == snapshot)
    }
}
