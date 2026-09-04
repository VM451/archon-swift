import Foundation

/// A vector record owned by Archon’s durable memory layer.
///
/// An index stores only the stable identifier and embedding. Memory text,
/// metadata, temporal validity, tombstones, history, and synchronization stay
/// in `VectorStore`, which remains the source of truth.
public struct VectorIndexRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let vector: [Float]

    public init(id: UUID, vector: [Float]) {
        self.id = id
        self.vector = vector
    }
}

/// A bounded vector query for an Archon-owned index.
///
/// `allowedIDs` is the result of applying Archon memory scope, metadata,
/// deletion, and temporal filters against the durable store. An approximate
/// index must never broaden that allow-list.
public struct VectorIndexQuery: Hashable, Sendable {
    public let vector: [Float]
    public let limit: Int
    public let allowedIDs: Set<UUID>?

    public init(vector: [Float], limit: Int, allowedIDs: Set<UUID>? = nil) {
        self.vector = vector
        self.limit = limit
        self.allowedIDs = allowedIDs
    }
}

/// A vector match normalized to Archon’s higher-is-better similarity scale.
public struct VectorIndexMatch: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let similarity: Float

    public init(id: UUID, similarity: Float) {
        self.id = id
        self.similarity = similarity
    }
}

/// Typed failures shared by built-in and optional vector-index adapters.
public enum VectorIndexError: Error, LocalizedError, Equatable, Sendable {
    case emptyVector
    case invalidDimension(expected: Int, actual: Int)
    case invalidLimit(Int)
    case nonFiniteComponent
    case duplicateID(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyVector:
            "A vector index cannot store or query an empty vector."
        case .invalidDimension(let expected, let actual):
            "Vector dimension \(actual) does not match the index dimension \(expected)."
        case .invalidLimit(let limit):
            "Vector index result limit \(limit) is outside the supported range 0...500."
        case .nonFiniteComponent:
            "A vector index requires finite vector components."
        case .duplicateID(let id):
            "A vector index rebuild contains duplicate ID \(id.uuidString)."
        }
    }
}

/// The minimal vendor-neutral seam for optional dense vector indexes.
///
/// Implementations may be exact or approximate and may be resident or
/// persistent. Persistence, rebuilding, and recovery must remain explicit;
/// conforming to this protocol alone does not authorize replacing Archon’s
/// durable memory store.
public protocol VectorIndex: Sendable {
    /// The fixed number of components accepted by this index.
    var dimension: Int { get }

    /// The number of indexed IDs currently present.
    var count: Int { get async }

    /// Replaces the complete index contents as one logical operation.
    func rebuild(_ records: [VectorIndexRecord]) async throws

    /// Inserts or replaces the vector for an ID.
    func upsert(id: UUID, vector: [Float]) async throws

    /// Removes an ID and reports whether it was present.
    @discardableResult
    func remove(id: UUID) async throws -> Bool

    /// Returns at most `query.limit` matches, sorted by descending similarity.
    func search(_ query: VectorIndexQuery) async throws -> [VectorIndexMatch]
}
