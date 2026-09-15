import Foundation

/// Built-in exact in-memory dense vector index.
///
/// This is the deterministic local-only default behind the `VectorIndex` seam:
/// brute-force cosine similarity, no persistence, no network, no third-party
/// dependency. Approximate or accelerated adapters (e.g. the optional
/// `ArchonMemoryProxima` target) conform to the same protocol and must honor
/// the same fail-closed contract. The durable `VectorStore` remains the
/// source of truth; this index never broadens `allowedIDs`.
public actor InMemoryVectorIndex: VectorIndex {
    public nonisolated let dimension: Int
    private var vectors: [UUID: [Float]] = [:]

    public init(dimension: Int) throws {
        guard dimension > 0 else {
            throw VectorIndexError.invalidDimension(expected: 1, actual: dimension)
        }
        self.dimension = dimension
    }

    public var count: Int { vectors.count }

    public func rebuild(_ records: [VectorIndexRecord]) throws {
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

    public func upsert(id: UUID, vector: [Float]) throws {
        try validate(vector)
        vectors[id] = vector
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        vectors.removeValue(forKey: id) != nil
    }

    public func search(_ query: VectorIndexQuery) throws -> [VectorIndexMatch] {
        guard (0...500).contains(query.limit) else {
            throw VectorIndexError.invalidLimit(query.limit)
        }
        try validate(query.vector)
        guard query.limit > 0 else { return [] }
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
            throw VectorIndexError.invalidDimension(expected: dimension, actual: vector.count)
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw VectorIndexError.nonFiniteComponent
        }
    }
}
