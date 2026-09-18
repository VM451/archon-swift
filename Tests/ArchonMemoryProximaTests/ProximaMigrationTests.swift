import Foundation
import ArchonMemory
import ArchonMemoryProxima
import Testing

private struct MigrationRNG {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000.0 - 0.5
    }
}

private func normalizedMigrationVector(rng: inout MigrationRNG, dimensions: Int) -> [Float] {
    let raw = (0..<dimensions).map { _ in rng.nextFloat() }
    let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else { return raw }
    return raw.map { $0 / norm }
}

private func cosineMigration(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    for index in a.indices { dot += a[index] * b[index] }
    return dot
}

private struct StaticRebuildSource: ArchonMemory.VectorIndexRebuildSource {
    let records: [ArchonMemory.VectorIndexRecord]

    func indexRecords() async throws -> [ArchonMemory.VectorIndexRecord] {
        records
    }
}

@Suite("Proxima Migration and Recovery Tests")
struct ProximaMigrationTests {
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
        var rng = MigrationRNG(state: seed)
        return (0..<count).map { _ in
            ArchonMemory.VectorIndexRecord(
                id: UUID(),
                vector: normalizedMigrationVector(rng: &rng, dimensions: Self.dimensions)
            )
        }
    }

    private func makeQueries(seed: UInt64) -> [[Float]] {
        var rng = MigrationRNG(state: seed)
        return (0..<Self.queryCount).map { _ in
            normalizedMigrationVector(rng: &rng, dimensions: Self.dimensions)
        }
    }

    private func makeDurableStore(records: [ArchonMemory.VectorIndexRecord]) async throws -> LocalVectorStore {
        let store = try LocalVectorStore(inMemory: true)
        try await store.saveBatch(items: records.enumerated().map { position, record in
            MemoryItem(
                id: record.id,
                memory: "Migration record \(position)",
                vector: record.vector,
                userId: "migration-user"
            )
        })
        return store
    }

    private func recall(
        index: ProximaVectorIndexAdapter,
        queries: [[Float]],
        records: [ArchonMemory.VectorIndexRecord],
        limit: Int,
        allowedIDs: Set<UUID>? = nil
    ) async throws -> Float {
        var recalls: [Float] = []
        for query in queries {
            let candidates = records.filter { allowedIDs?.contains($0.id) ?? true }
            let truth = Set(candidates
                .map { ($0.id, cosineMigration(query, $0.vector)) }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map(\.0))
            let results = try await index.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: limit, allowedIDs: allowedIDs)
            )
            let hits = results.filter { truth.contains($0.id) }.count
            recalls.append(Float(hits) / Float(limit))
        }
        return recalls.reduce(0, +) / Float(recalls.count)
    }

    @Test("Migrating a 500-record durable store holds Recall@10 at or above 0.99")
    func migrateHoldsRecallBar() async throws {
        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let store = try await makeDurableStore(records: records)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)

        let report = try await index.migrate(from: store)
        #expect(report.indexed == Self.corpusSize)
        #expect(report.skipped == 0)
        #expect(report.bytes > 0)
        #expect(await index.count == Self.corpusSize)

        let mean = try await recall(
            index: index,
            queries: makeQueries(seed: 0xBEA7C0),
            records: records,
            limit: Self.topK
        )
        #expect(mean >= 0.99)
    }

    @Test("Migration skips unindexable records and reports them")
    func migrateSkipsUnindexable() async throws {
        let good = makeRecords(count: 3, seed: 0x5EED)
        let source = StaticRebuildSource(records: good + [
            ArchonMemory.VectorIndexRecord(id: UUID(), vector: [0.5]),
            ArchonMemory.VectorIndexRecord(id: UUID(), vector: []),
            ArchonMemory.VectorIndexRecord(id: UUID(), vector: [Float](repeating: .nan, count: Self.dimensions)),
        ])
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let report = try await index.migrate(from: source)
        #expect(report.indexed == 3)
        #expect(report.skipped == 3)
        #expect(await index.count == 3)
    }

    @Test("Corrupt snapshots rebuild from durable truth with exact results")
    func restoreOrRebuildRecoversExactly() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-migrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let queries = makeQueries(seed: 0xBEA7C0)
        let store = try await makeDurableStore(records: records)

        let source = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await source.rebuild(records)
        var before: [[UUID]] = []
        for query in queries {
            let results = try await source.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            before.append(results.map(\.id))
        }

        // Healthy snapshot path restores without rebuilding.
        try await source.persist(to: snapshotURL)
        let healthy = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let restored = try await healthy.restoreOrRebuild(snapshot: snapshotURL, fallback: store)
        #expect(!restored)
        #expect(await healthy.count == Self.corpusSize)

        // Corrupt snapshot path rebuilds from durable truth.
        try Data("not-json".utf8).write(to: snapshotURL)
        let recovered = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let rebuilt = try await recovered.restoreOrRebuild(snapshot: snapshotURL, fallback: store)
        #expect(rebuilt)
        #expect(await recovered.count == Self.corpusSize)
        for (position, query) in queries.enumerated() {
            let results = try await recovered.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            #expect(results.map(\.id) == before[position])
        }
    }

    @Test("Ceiling breaches fail closed before any write")
    func ceilingBreachFailsClosed() async throws {
        let records = makeRecords(count: 50, seed: 0xCE11)
        let store = try await makeDurableStore(records: records)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let stableID = records[0].id
        try await index.upsert(id: stableID, vector: records[0].vector)
        try await index.upsert(id: records[1].id, vector: records[1].vector)

        await #expect(throws: ProximaVectorIndexError.recordLimitExceeded(maximum: 10, actual: 50)) {
            try await index.migrate(
                from: store,
                ceiling: ProximaResourceCeiling(maxRecords: 10, maxSnapshotBytes: 16_777_216)
            )
        }
        do {
            try await index.migrate(
                from: store,
                ceiling: ProximaResourceCeiling(maxRecords: 20_000, maxSnapshotBytes: 64)
            )
            Issue.record("Expected a snapshot budget breach.")
        } catch let error as ProximaVectorIndexError {
            guard case .snapshotBudgetExceeded(let maximum, let actual) = error else {
                Issue.record("Wrong typed error: \(error).")
                return
            }
            #expect(maximum == 64)
            #expect(actual > 64)
        }
        // The previously serving index is untouched by both breaches.
        #expect(await index.count == 2)
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: records[0].vector, limit: 1)
        )
        #expect(results.first?.id == stableID)

        // Persist under a breached budget leaves the existing file untouched.
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-ceiling-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        try await index.persist(to: snapshotURL)
        let before = try Data(contentsOf: snapshotURL)
        await #expect(throws: ProximaVectorIndexError.snapshotBudgetExceeded(
            maximumBytes: 64,
            actualBytes: before.count
        )) {
            try await index.persist(
                to: snapshotURL,
                ceiling: ProximaResourceCeiling(maxRecords: 20_000, maxSnapshotBytes: 64)
            )
        }
        #expect(try Data(contentsOf: snapshotURL) == before)
    }

    @Test("Cancellation mid-migrate leaves the old index serving")
    func cancellationKeepsOldIndex() async throws {
        let records = makeRecords(count: Self.corpusSize, seed: 0xCA9CE1)
        let store = try await makeDurableStore(records: records)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        try await index.upsert(id: records[0].id, vector: records[0].vector)

        let task = Task { try await index.migrate(from: store) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await index.count == 1)
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: records[0].vector, limit: 1)
        )
        #expect(results.first?.id == records[0].id)
    }

    @Test("Filtered 10 percent allow-list holds recall parity via overfetch")
    func filteredAllowListRecallParity() async throws {
        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let store = try await makeDurableStore(records: records)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let report = try await index.migrate(from: store)
        #expect(report.indexed == Self.corpusSize)

        let allowed = Set(records.prefix(50).map(\.id))
        let queries = makeQueries(seed: 0xBEA7C0)
        let mean = try await recall(
            index: index,
            queries: queries,
            records: records,
            limit: Self.topK,
            allowedIDs: allowed
        )
        #expect(mean >= 0.99)

        // The allow-list is never broadened.
        let results = try await index.search(
            ArchonMemory.VectorIndexQuery(vector: queries[0], limit: Self.topK, allowedIDs: allowed)
        )
        #expect(results.count == Self.topK)
        #expect(Set(results.map(\.id)).isSubset(of: allowed))
    }

    @Test("Migration report bytes match the persisted snapshot budget")
    func migrationReportMatchesSnapshotBudget() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxima-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let records = makeRecords(count: Self.corpusSize, seed: 0xA2C40D)
        let store = try await makeDurableStore(records: records)
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let report = try await index.migrate(from: store)
        try await index.persist(to: snapshotURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let bytes = attributes[.size] as? Int ?? -1
        #expect(bytes == report.bytes)
        // 500 records x 32 dims must fit well under half a megabyte on-device.
        #expect(report.bytes < 512_000)
    }
}
