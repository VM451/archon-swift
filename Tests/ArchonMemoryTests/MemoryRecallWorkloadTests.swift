import Testing
import Foundation
@testable import ArchonMemory

@Suite("Batch Cosine Equivalence Tests")
struct BatchCosineEquivalenceTests {
    @Test("Batch scoring matches scalar scoring within rounding")
    func testBatchMatchesScalar() {
        var rng = WorkloadRNG(state: 0xBA7C)
        let query = (0..<64).map { _ in rng.nextFloat() }
        var rows: [[Float]] = (0..<200).map { _ in (0..<64).map { _ in rng.nextFloat() } }
        rows.append(contentsOf: [
            [Float](repeating: 0, count: 64),
            [Float](repeating: 1, count: 32),
            [],
            [Float](repeating: 1e20, count: 64),
        ])
        let batch = VectorMath.batchCosineSimilarities(query: query, rows: rows)
        #expect(batch.count == rows.count)
        for (index, row) in rows.enumerated() {
            let scalar = VectorMath.cosineSimilarity(query, row)
            if row.count != query.count {
                #expect(batch[index] == 0)
            } else {
                #expect(abs(batch[index] - scalar) < 1e-5)
            }
        }
    }
}

/// Deterministic xorshift generator so the canonical workload is stable
/// across runs, machines, and suite orderings.
private struct WorkloadRNG {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000.0 - 0.5
    }
}

@Suite("Memory Recall Workload Tests")
struct MemoryRecallWorkloadTests {
    private static let corpusSize = 500
    private static let dimensions = 32
    private static let queryCount = 10
    private static let topK = 10

    private func makeCorpus() -> [MemoryItem] {
        var rng = WorkloadRNG(state: 0xA2C40D)
        return (0..<Self.corpusSize).map { index in
            let raw = (0..<Self.dimensions).map { _ in rng.nextFloat() }
            return MemoryItem(
                memory: "Canonical workload fact \(index)",
                vector: VectorMath.normalize(raw),
                userId: "workload-user"
            )
        }
    }

    private func exactTopK(query: [Float], corpus: [MemoryItem], k: Int) -> [UUID] {
        corpus
            .map { ($0.id, VectorMath.cosineSimilarity(query, $0.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map(\.0)
    }

    @Test("Canonical workload holds Recall@10 at or above 0.99")
    func testCanonicalRecallAtTen() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 1, beta: 0)
        let corpus = makeCorpus()
        try await store.saveBatch(items: corpus)

        var rng = WorkloadRNG(state: 0xBEA7C0)
        var recalls: [Float] = []
        for _ in 0..<Self.queryCount {
            let query = VectorMath.normalize((0..<Self.dimensions).map { _ in rng.nextFloat() })
            let truth = Set(exactTopK(query: query, corpus: corpus, k: Self.topK))
            let results = try await store.search(
                query: nil,
                vector: query,
                limit: Self.topK,
                filters: MemoryFilter()
            )
            let hits = results.filter { truth.contains($0.item.id) }.count
            recalls.append(Float(hits) / Float(Self.topK))
        }

        let mean = recalls.reduce(0, +) / Float(recalls.count)
        #expect(mean >= 0.99)
        #expect(recalls.allSatisfy { $0 >= 0.9 })
    }

    @Test("Temporal search excludes expired and future facts but preserves history")
    func testTemporalExclusionPreservesHistory() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let now = Date()
        let active = MemoryItem(memory: "Current capital fact", vector: [1, 0], userId: "u1")
        let expired = MemoryItem(
            memory: "Old capital fact",
            vector: [1, 0],
            userId: "u1",
            validFrom: now.addingTimeInterval(-7200),
            validTo: now.addingTimeInterval(-3600)
        )
        let future = MemoryItem(
            memory: "Future capital fact",
            vector: [1, 0],
            userId: "u1",
            validFrom: now.addingTimeInterval(3600)
        )
        try await store.save(item: active)
        try await store.save(item: expired)
        try await store.save(item: future)

        let results = try await store.search(
            query: "capital",
            vector: nil,
            limit: 10,
            filters: MemoryFilter(userId: "u1")
        )
        #expect(results.map(\.item.id) == [active.id])

        let timeless = try await store.search(
            query: "capital",
            vector: nil,
            limit: 10,
            filters: MemoryFilter(userId: "u1", activeAt: nil)
        )
        #expect(Set(timeless.map(\.item.id)) == Set([active.id, expired.id, future.id]))

        // History stays readable by direct fetch after temporal exclusion.
        #expect(try await store.fetch(id: expired.id)?.memory == "Old capital fact")
    }

    @Test("Superseded facts lose to their replacement in retrieval")
    func testSupersessionRetrieval() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let now = Date()
        let replacement = MemoryItem(memory: "User lives in Chiang Mai", vector: [0.9, 0.1], userId: "u1")
        var old = MemoryItem(memory: "User lives in Bangkok", vector: [0.9, 0.1], userId: "u1")
        old.validTo = now
        old.supersededById = replacement.id
        try await store.save(item: old)
        try await store.save(item: replacement)

        let results = try await store.search(
            query: "lives",
            vector: nil,
            limit: 10,
            filters: MemoryFilter(userId: "u1")
        )
        #expect(results.map(\.item.id) == [replacement.id])
        #expect(try await store.fetch(id: old.id)?.supersededById == replacement.id)
    }

    @Test("Scoped search cannot cross-read another user's memories")
    func testScopeIsolation() async throws {
        let store = try LocalVectorStore(inMemory: true)
        try await store.save(item: MemoryItem(memory: "Alice secret project", vector: [1, 0], userId: "alice"))
        try await store.save(item: MemoryItem(memory: "Bob secret project", vector: [1, 0], userId: "bob"))

        let bobResults = try await store.search(
            query: "secret project",
            vector: nil,
            limit: 10,
            filters: MemoryFilter(userId: "bob")
        )
        #expect(bobResults.map(\.item.id).count == 1)
        #expect(bobResults.allSatisfy { $0.item.userId == "bob" })
    }

    @Test("Nil-filter search defaults to active, non-deleted facts")
    func testNilFilterSearchDefaults() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let live = MemoryItem(memory: "Live fact", vector: [1, 0])
        let gone = MemoryItem(memory: "Deleted fact", vector: [1, 0])
        let expired = MemoryItem(
            memory: "Expired fact",
            vector: [1, 0],
            validFrom: Date().addingTimeInterval(-7200),
            validTo: Date().addingTimeInterval(-3600)
        )
        try await store.save(item: live)
        try await store.save(item: gone)
        try await store.save(item: expired)
        try await store.delete(id: gone.id)

        let results = try await store.search(query: "fact", vector: nil, limit: 10, filters: nil)
        #expect(results.map(\.item.id) == [live.id])
    }
}
