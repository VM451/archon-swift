import Foundation
import ArchonMemory
import ArchonMemoryProxima
import Testing

/// Deterministic xorshift generator matching the memory workload's stability
/// contract: same seeds, same corpus, every run.
private struct ProximaWorkloadRNG {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000.0 - 0.5
    }
}

private func normalizedProximaVector(rng: inout ProximaWorkloadRNG, dimensions: Int) -> [Float] {
    let raw = (0..<dimensions).map { _ in rng.nextFloat() }
    let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else { return raw }
    return raw.map { $0 / norm }
}

private func cosineProxima(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    for index in a.indices { dot += a[index] * b[index] }
    return dot
}

@Suite("Proxima Scale Workload Tests")
struct ProximaScaleWorkloadTests {
    private static let corpusSize = 500
    private static let dimensions = 32
    private static let queryCount = 10
    private static let topK = 10

    private let configuration = ProximaVectorIndexConfiguration(
        maximumConnections: 12,
        constructionSearchWidth: 100,
        querySearchWidth: 256,
        levelSeed: 42
    )

    private func makeRecords(count: Int, seed: UInt64) -> [ArchonMemory.VectorIndexRecord] {
        var rng = ProximaWorkloadRNG(state: seed)
        return (0..<count).map { _ in
            ArchonMemory.VectorIndexRecord(
                id: UUID(),
                vector: normalizedProximaVector(rng: &rng, dimensions: Self.dimensions)
            )
        }
    }

    private func makeQueries(seed: UInt64) -> [[Float]] {
        var rng = ProximaWorkloadRNG(state: seed)
        return (0..<Self.queryCount).map { _ in
            normalizedProximaVector(rng: &rng, dimensions: Self.dimensions)
        }
    }

    private func exactTopK(
        query: [Float],
        records: [ArchonMemory.VectorIndexRecord],
        k: Int
    ) -> Set<UUID> {
        Set(records
            .map { ($0.id, cosineProxima(query, $0.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map(\.0))
    }

    @Test("Adapter holds Recall@10 at or above 0.99 on the canonical corpus")
    func testRecallParity() async throws {
        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await index.rebuild(records)

        var recalls: [Float] = []
        for query in makeQueries(seed: 0xBEA7C0) {
            let truth = exactTopK(query: query, records: records, k: Self.topK)
            let results = try await index.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            let hits = results.filter { truth.contains($0.id) }.count
            recalls.append(Float(hits) / Float(Self.topK))
        }

        let mean = recalls.reduce(0, +) / Float(recalls.count)
        #expect(mean >= 0.99)
    }

    @Test("Bulk update and delete workload keeps the index exact")
    func testBulkChurn() async throws {
        let records = makeRecords(count: 200, seed: 0xC42001)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await index.rebuild(records)

        // Update half with fresh vectors.
        var rng = ProximaWorkloadRNG(state: 0x0DA7E)
        var updated: [(UUID, [Float])] = []
        for record in records.prefix(100) {
            let vector = normalizedProximaVector(rng: &rng, dimensions: Self.dimensions)
            try await index.upsert(id: record.id, vector: vector)
            updated.append((record.id, vector))
        }

        // Delete a quarter of the untouched half.
        let doomed = records.dropFirst(100).prefix(50).map(\.id)
        for id in doomed {
            #expect(try await index.remove(id: id))
        }
        #expect(await index.count == 150)

        // Removed IDs never surface, even in an unbounded scan.
        let scanned = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: updated[0].1, limit: 150)
        )
        #expect(Set(scanned.map(\.id)).isDisjoint(with: doomed))

        // Every updated vector resolves to its own ID at rank 1.
        for (id, vector) in updated {
            let top = try await index.search(
                ArchonMemory.VectorIndexQuery(vector: vector, limit: 1)
            )
            #expect(top.first?.id == id)
        }
    }

    @Test("Persist, crash, and restore preserves search results exactly")
    func testCrashRecoveryParity() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-scale-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let queries = makeQueries(seed: 0xBEA7C0)
        let source = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await source.rebuild(records)
        var before: [[UUID]] = []
        for query in queries {
            let results = try await source.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            before.append(results.map(\.id))
        }
        try await source.persist(to: snapshotURL)

        // Fresh process: a brand-new instance restores the snapshot.
        let restored = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await restored.restore(from: snapshotURL)
        #expect(await restored.count == Self.corpusSize)
        for (position, query) in queries.enumerated() {
            let results = try await restored.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            #expect(results.map(\.id) == before[position])
        }
    }

    @Test("Restore from missing or corrupt snapshots fails with typed errors")
    func testRestoreFailuresAreTyped() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-missing-\(UUID().uuidString).json")
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-corrupt-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: missingURL)
            try? FileManager.default.removeItem(at: corruptURL)
        }
        try Data("not-json".utf8).write(to: corruptURL)

        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        await #expect(throws: ProximaVectorIndexError.self) {
            try await index.restore(from: missingURL)
        }
        await #expect(throws: ProximaVectorIndexError.self) {
            try await index.restore(from: corruptURL)
        }
        #expect(await index.count == 0)
    }

    @Test("Snapshot size stays under the documented device budget")
    func testSnapshotCeiling() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await index.rebuild(records)
        try await index.persist(to: snapshotURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let bytes = attributes[.size] as? Int ?? Int.max
        // 500 records x 32 dims must fit well under half a megabyte on-device.
        #expect(bytes < 512_000)
    }

    @Test("Allow-listed search at scale stays inside the list and best-first")
    func testFilteredSearchAtScale() async throws {
        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await index.rebuild(records)

        let allowed = Set(records.prefix(50).map(\.id))
        let query = makeQueries(seed: 0xBEA7C0)[0]
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: query, limit: 50, allowedIDs: allowed)
        )

        #expect(results.count == 50)
        #expect(Set(results.map(\.id)) == allowed)
        let similarities = results.map(\.similarity)
        #expect(zip(similarities, similarities.dropFirst()).allSatisfy { $0 >= $1 })
    }
}
