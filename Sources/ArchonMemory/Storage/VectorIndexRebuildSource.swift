import Foundation

/// Durable-store truth for rebuilding any derived vector index.
///
/// Migration (durable store to a new index) and recovery (rebuild after a
/// lost or corrupt snapshot) both read from this seam so the index can never
/// invent records: every rebuilt vector originates from the authoritative
/// store. Implementations return non-deleted rows only, stream in bounded
/// batches, and honor structured cancellation.
///
/// Skipped rows (deleted, embedding-less, or otherwise unindexable) are
/// simply absent from the result; the rebuilding adapter reports its own
/// indexed/skipped accounting.
public protocol VectorIndexRebuildSource: Sendable {
    /// Returns every indexable record in a deterministic order.
    func indexRecords() async throws -> [VectorIndexRecord]
}
