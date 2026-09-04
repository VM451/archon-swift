import Foundation
import Testing
@testable import ArchonMemory

private actor ReferenceVectorIndex: VectorIndex {
    nonisolated let dimension: Int
    private var vectors: [UUID: [Float]] = [:]

    init(dimension: Int) {
        self.dimension = dimension
    }

    var count: Int { vectors.count }

    func rebuild(_ records: [VectorIndexRecord]) throws {
        var replacement: [UUID: [Float]] = [:]
        replacement.reserveCapacity(records.count)
        for record in records {
            guard replacement[record.id] == nil else {
                throw VectorIndexError.duplicateID(record.id)
            }
            try validate(record.vector)
            replacement[record.id] = record.vector
        }
        vectors = replacement
    }

    func upsert(id: UUID, vector: [Float]) throws {
        try validate(vector)
        vectors[id] = vector
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        vectors.removeValue(forKey: id) != nil
    }

    func search(_ query: VectorIndexQuery) throws -> [VectorIndexMatch] {
        guard (0...500).contains(query.limit) else {
            throw VectorIndexError.invalidLimit(query.limit)
        }
        try validate(query.vector)
        let matches = vectors.compactMap { id, vector -> VectorIndexMatch? in
            guard query.allowedIDs?.contains(id) ?? true else { return nil }
            return VectorIndexMatch(
                id: id,
                similarity: VectorMath.cosineSimilarity(query.vector, vector)
            )
        }
        return Array(
            matches.sorted {
                if $0.similarity != $1.similarity {
                    return $0.similarity > $1.similarity
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(query.limit)
        )
    }

    private func validate(_ vector: [Float]) throws {
        guard !vector.isEmpty else { throw VectorIndexError.emptyVector }
        guard vector.count == dimension else {
            throw VectorIndexError.invalidDimension(
                expected: dimension,
                actual: vector.count
            )
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw VectorIndexError.nonFiniteComponent
        }
    }
}

@Suite("Vector Index Contract Tests")
struct VectorIndexContractTests {
    @Test("Index upsert replaces and remove reports presence")
    func upsertAndRemove() async throws {
        let index = ReferenceVectorIndex(dimension: 2)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        try await index.upsert(id: id, vector: [1, 0])
        #expect(await index.count == 1)
        try await index.upsert(id: id, vector: [0, 1])
        #expect(await index.count == 1)
        let removed = await index.remove(id: id)
        let removedAgain = await index.remove(id: id)
        #expect(removed)
        #expect(!removedAgain)
    }

    @Test("Index search enforces allow-list, limit, and deterministic ordering")
    func filteredSearch() async throws {
        let index = ReferenceVectorIndex(dimension: 2)
        let bestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try await index.rebuild([
            VectorIndexRecord(id: bestID, vector: [1, 0]),
            VectorIndexRecord(id: otherID, vector: [0, 1])
        ])

        let results = try await index.search(
            VectorIndexQuery(
                vector: [1, 0],
                limit: 1,
                allowedIDs: [otherID]
            )
        )
        #expect(results.map(\.id) == [otherID])
        #expect(results.first?.similarity == 0)
    }

    @Test("Failed rebuild preserves the previous index snapshot")
    func rebuildIsLogicalReplacement() async throws {
        let index = ReferenceVectorIndex(dimension: 2)
        let stableID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try await index.upsert(id: stableID, vector: [1, 0])

        await #expect(throws: VectorIndexError.duplicateID(duplicateID)) {
            try await index.rebuild([
                VectorIndexRecord(id: duplicateID, vector: [0, 1]),
                VectorIndexRecord(id: duplicateID, vector: [1, 1])
            ])
        }

        #expect(await index.count == 1)
        let results = try await index.search(VectorIndexQuery(vector: [1, 0], limit: 1))
        #expect(results.first?.id == stableID)
    }
}
