import Foundation
import Testing
@testable import ArchonMemory

@Suite("InMemory Vector Index Hardening")
struct InMemoryVectorIndexTests {
    @Test("Upsert, allow-list, limit, and deterministic ordering")
    func contract() async throws {
        let index = try InMemoryVectorIndex(dimension: 2)
        let best = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try await index.rebuild([
            VectorIndexRecord(id: best, vector: [1, 0]),
            VectorIndexRecord(id: other, vector: [0, 1]),
        ])
        #expect(await index.count == 2)
        let limited = try await index.search(
            VectorIndexQuery(vector: [1, 0], limit: 1, allowedIDs: [other]))
        #expect(limited.map(\.id) == [other])
        let ranked = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 10))
        #expect(ranked.map(\.id) == [best, other])
        #expect(ranked[0].similarity >= ranked[1].similarity)
    }

    @Test("Fail-closed validation and failed rebuild preserves snapshot")
    func failClosed() async throws {
        let index = try InMemoryVectorIndex(dimension: 2)
        let stable = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let dupe = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try await index.upsert(id: stable, vector: [1, 0])
        await #expect(throws: VectorIndexError.emptyVector) {
            try await index.upsert(id: UUID(), vector: [])
        }
        await #expect(throws: VectorIndexError.nonFiniteComponent) {
            try await index.upsert(id: UUID(), vector: [Float.nan, 0])
        }
        await #expect(throws: VectorIndexError.invalidDimension(expected: 2, actual: 3)) {
            try await index.upsert(id: UUID(), vector: [1, 0, 0])
        }
        await #expect(throws: VectorIndexError.invalidLimit(501)) {
            try await index.search(VectorIndexQuery(vector: [1, 0], limit: 501))
        }
        await #expect(throws: VectorIndexError.duplicateID(dupe)) {
            try await index.rebuild([
                VectorIndexRecord(id: dupe, vector: [1, 0]),
                VectorIndexRecord(id: dupe, vector: [0, 1]),
            ])
        }
        #expect(await index.count == 1)
        #expect(throws: VectorIndexError.invalidDimension(expected: 1, actual: 0)) {
            try InMemoryVectorIndex(dimension: 0)
        }
    }

    @Test("Remove reports presence and zero limit returns empty")
    func removeAndZeroLimit() async throws {
        let index = try InMemoryVectorIndex(dimension: 2)
        let id = UUID()
        try await index.upsert(id: id, vector: [1, 0])
        #expect(await index.remove(id: id) == true)
        #expect(await index.remove(id: id) == false)
        try await index.upsert(id: id, vector: [1, 0])
        let empty = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 0))
        #expect(empty.isEmpty)
    }
}
