import ArchonMemory
import Foundation
import ProximaKit

/// Configuration for the optional ProximaKit-backed dense index.
///
/// These are Archon-owned values so callers do not need to import or understand
/// ProximaKit configuration types. A fixed seed is useful for reproducible
/// tests and benchmarks; `nil` uses the candidate's default random level draw.
public struct ProximaVectorIndexConfiguration: Codable, Equatable, Hashable, Sendable {
    public let maximumConnections: Int
    public let constructionSearchWidth: Int
    public let querySearchWidth: Int
    public let levelSeed: UInt64?

    public init(
        maximumConnections: Int = 16,
        constructionSearchWidth: Int = 200,
        querySearchWidth: Int = 50,
        levelSeed: UInt64? = nil
    ) {
        self.maximumConnections = maximumConnections
        self.constructionSearchWidth = constructionSearchWidth
        self.querySearchWidth = querySearchWidth
        self.levelSeed = levelSeed
    }

    public static let standard = ProximaVectorIndexConfiguration()
}

public enum ProximaVectorIndexError: Error, LocalizedError, Equatable, Sendable {
    case invalidDimension(Int)
    case invalidConfiguration(String)
    case busy
    case candidateFailure(String)
    case persistenceFailure(String)
    case recordLimitExceeded(maximum: Int, actual: Int)
    case snapshotBudgetExceeded(maximumBytes: Int, actualBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDimension(let dimension):
            "Proxima vector index dimension must be positive: \(dimension)."
        case .invalidConfiguration(let message):
            "Invalid Proxima vector index configuration: \(message)."
        case .busy:
            "The Proxima vector index is rebuilding; retry the mutation later."
        case .candidateFailure(let message):
            "The Proxima vector index failed: \(message)."
        case .persistenceFailure(let message):
            "Proxima vector index persistence failed: \(message)."
        case .recordLimitExceeded(let maximum, let actual):
            "Proxima vector index record count \(actual) exceeds the ceiling of \(maximum); refusing to rebuild."
        case .snapshotBudgetExceeded(let maximum, let actual):
            "Proxima vector index snapshot of \(actual) bytes exceeds the budget of \(maximum) bytes; refusing to write."
        }
    }
}

/// Fail-closed resource ceiling for Proxima index migration and persistence.
///
/// Migration refuses to rebuild when the source yields more than `maxRecords`
/// indexable records, and persistence refuses to write a snapshot larger
/// than `maxSnapshotBytes`. Both checks run before any write, so a breach
/// leaves the previously serving index (and any existing snapshot) untouched.
/// Defaults are conservative placeholders until iPhone-class measurement
/// lands; see the memory-proxima product page.
public struct ProximaResourceCeiling: Codable, Equatable, Hashable, Sendable {
    public var maxRecords: Int
    public var maxSnapshotBytes: Int

    public init(maxRecords: Int = 20_000, maxSnapshotBytes: Int = 16_777_216) {
        self.maxRecords = max(0, maxRecords)
        self.maxSnapshotBytes = max(0, maxSnapshotBytes)
    }

    public static let standard = ProximaResourceCeiling()
}

/// Accounting for one `migrate(from:ceiling:)` run.
public struct ProximaMigrationReport: Codable, Equatable, Hashable, Sendable {
    /// Records accepted into the rebuilt index.
    public let indexed: Int
    /// Source records skipped as unindexable (empty vector, dimension
    /// mismatch, or non-finite component). Deleted and embedding-less rows
    /// never leave the durable store, so they are not counted here.
    public let skipped: Int
    /// Encoded JSON snapshot size in bytes for the rebuilt contents.
    public let bytes: Int

    public init(indexed: Int, skipped: Int, bytes: Int) {
        self.indexed = indexed
        self.skipped = skipped
        self.bytes = bytes
    }
}

public struct ProximaVectorIndexSnapshot: Codable, Equatable, Sendable {
    public let dimension: Int
    public let configuration: ProximaVectorIndexConfiguration
    public let records: [ArchonMemory.VectorIndexRecord]

    public init(
        dimension: Int,
        configuration: ProximaVectorIndexConfiguration,
        records: [ArchonMemory.VectorIndexRecord]
    ) {
        self.dimension = dimension
        self.configuration = configuration
        self.records = records
    }
}

/// Optional Archon adapter for ProximaKit's local Accelerate HNSW index.
///
/// The durable `ArchonMemory` store remains authoritative. This adapter stores
/// only vector IDs and embeddings, applies Archon's allow-list before returning
/// results, and translates Proxima's lower-is-better cosine distance into
/// Archon's higher-is-better similarity scale.
public actor ProximaVectorIndexAdapter: ArchonMemory.VectorIndex {
    public nonisolated let dimension: Int
    public nonisolated let configuration: ProximaVectorIndexConfiguration

    private var index: HNSWIndex
    private var records: [UUID: [Float]] = [:]
    private var rebuilding = false

    public init(
        dimension: Int,
        configuration: ProximaVectorIndexConfiguration = .standard
    ) throws {
        guard dimension > 0 else {
            throw ProximaVectorIndexError.invalidDimension(dimension)
        }
        try Self.validate(configuration)

        self.dimension = dimension
        self.configuration = configuration
        self.index = HNSWIndex(
            dimension: dimension,
            metric: CosineDistance(),
            config: HNSWConfiguration(
                m: configuration.maximumConnections,
                efConstruction: configuration.constructionSearchWidth,
                efSearch: configuration.querySearchWidth,
                autoCompactionThreshold: 0.7,
                levelSeed: configuration.levelSeed
            )
        )
    }

    public var count: Int {
        records.count
    }

    public func persist(to url: URL) throws {
        try persist(to: url, ceiling: nil)
    }

    /// Persists a snapshot, refusing to write when `ceiling` is breached.
    ///
    /// The snapshot is encoded and measured before any filesystem write, so a
    /// budget breach leaves any existing snapshot untouched. A `nil` ceiling
    /// preserves the unbounded legacy behavior.
    public func persist(to url: URL, ceiling: ProximaResourceCeiling?) throws {
        guard url.isFileURL else {
            throw ProximaVectorIndexError.persistenceFailure("The snapshot URL must be a file URL.")
        }
        do {
            let data = try Self.encodedSnapshot(
                dimension: dimension,
                configuration: configuration,
                records: records.map { ArchonMemory.VectorIndexRecord(id: $0.key, vector: $0.value) }
            )
            if let ceiling, data.count > ceiling.maxSnapshotBytes {
                throw ProximaVectorIndexError.snapshotBudgetExceeded(
                    maximumBytes: ceiling.maxSnapshotBytes,
                    actualBytes: data.count
                )
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch let error as ProximaVectorIndexError {
            throw error
        } catch {
            throw ProximaVectorIndexError.persistenceFailure(error.localizedDescription)
        }
    }

    public func restore(from url: URL) async throws {
        guard url.isFileURL else {
            throw ProximaVectorIndexError.persistenceFailure("The snapshot URL must be a file URL.")
        }
        do {
            let snapshot = try JSONDecoder().decode(
                ProximaVectorIndexSnapshot.self,
                from: Data(contentsOf: url)
            )
            guard snapshot.dimension == dimension else {
                throw ProximaVectorIndexError.invalidDimension(snapshot.dimension)
            }
            try await rebuild(snapshot.records)
        } catch let error as ProximaVectorIndexError {
            throw error
        } catch {
            throw ProximaVectorIndexError.persistenceFailure(error.localizedDescription)
        }
    }

    public func rebuild(_ records: [ArchonMemory.VectorIndexRecord]) async throws {
        guard !rebuilding else {
            throw ProximaVectorIndexError.busy
        }
        rebuilding = true
        defer { rebuilding = false }

        var seenIDs = Set<UUID>()
        seenIDs.reserveCapacity(records.count)
        let replacement = HNSWIndex(
            dimension: dimension,
            metric: CosineDistance(),
            config: HNSWConfiguration(
                m: configuration.maximumConnections,
                efConstruction: configuration.constructionSearchWidth,
                efSearch: configuration.querySearchWidth,
                autoCompactionThreshold: 0.7,
                levelSeed: configuration.levelSeed
            )
        )

        do {
            for record in records {
                try Task.checkCancellation()
                guard seenIDs.insert(record.id).inserted else {
                    throw ArchonMemory.VectorIndexError.duplicateID(record.id)
                }
                try Self.validate(record.vector, dimension: dimension)
                try await replacement.add(
                    Vector(record.vector),
                    id: record.id
                )
            }
            try Task.checkCancellation()
            index = replacement
            self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.vector) })
        } catch let error as ArchonMemory.VectorIndexError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProximaVectorIndexError.candidateFailure(error.localizedDescription)
        }
    }

    /// Rebuilds the index, refusing to start when `ceiling` is breached.
    ///
    /// The record-count check runs before the replacement index is built, so
    /// a breach (or a duplicate ID, invalid vector, or cancellation) leaves
    /// the previously serving index untouched.
    public func rebuild(
        _ records: [ArchonMemory.VectorIndexRecord],
        ceiling: ProximaResourceCeiling
    ) async throws {
        guard records.count <= ceiling.maxRecords else {
            throw ProximaVectorIndexError.recordLimitExceeded(
                maximum: ceiling.maxRecords,
                actual: records.count
            )
        }
        try await rebuild(records)
    }

    /// Migrates a durable store's contents into this index.
    ///
    /// Reads every indexable record from `source`, skips records this index
    /// cannot hold (empty vector, dimension mismatch, non-finite component),
    /// enforces `ceiling` before any write, then atomically rebuilds. A
    /// ceiling breach, duplicate ID, or cancellation leaves the previously
    /// serving index untouched, so rollback is "keep serving the old index".
    /// Only typed `ProximaVectorIndexError`, `ArchonMemory.VectorIndexError`,
    /// `ArchonMemoryError`, and `CancellationError` failures escape.
    public func migrate(
        from source: any ArchonMemory.VectorIndexRebuildSource,
        ceiling: ProximaResourceCeiling = .standard
    ) async throws -> ProximaMigrationReport {
        try Task.checkCancellation()
        let sourced = try await source.indexRecords()
        try Task.checkCancellation()

        var indexable: [ArchonMemory.VectorIndexRecord] = []
        indexable.reserveCapacity(sourced.count)
        var skipped = 0
        for record in sourced {
            if Self.isIndexable(record.vector, dimension: dimension) {
                indexable.append(record)
            } else {
                skipped += 1
            }
        }

        guard indexable.count <= ceiling.maxRecords else {
            throw ProximaVectorIndexError.recordLimitExceeded(
                maximum: ceiling.maxRecords,
                actual: indexable.count
            )
        }
        let projected: Data
        do {
            projected = try Self.encodedSnapshot(
                dimension: dimension,
                configuration: configuration,
                records: indexable
            )
        } catch {
            throw ProximaVectorIndexError.persistenceFailure(error.localizedDescription)
        }
        guard projected.count <= ceiling.maxSnapshotBytes else {
            throw ProximaVectorIndexError.snapshotBudgetExceeded(
                maximumBytes: ceiling.maxSnapshotBytes,
                actualBytes: projected.count
            )
        }

        try await rebuild(indexable, ceiling: ceiling)
        return ProximaMigrationReport(indexed: indexable.count, skipped: skipped, bytes: projected.count)
    }

    /// Restores a snapshot, rebuilding from durable truth when it is unusable.
    ///
    /// - Returns: `false` when the snapshot restored normally, `true` when
    ///   the snapshot was missing, corrupt, or dimension-mismatched and the
    ///   index was instead rebuilt from `fallback`. The rebuild path skips
    ///   records this index cannot hold and enforces the standard ceiling
    ///   before any write; a breach surfaces as a typed error with the old
    ///   index still serving. Cancellation propagates without rebuilding.
    public func restoreOrRebuild(
        snapshot url: URL,
        fallback: any ArchonMemory.VectorIndexRebuildSource
    ) async throws -> Bool {
        do {
            try await restore(from: url)
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Snapshot unusable: fall through to durable-store recovery.
        }
        try Task.checkCancellation()
        let sourced = try await fallback.indexRecords()
        try Task.checkCancellation()
        var indexable: [ArchonMemory.VectorIndexRecord] = []
        indexable.reserveCapacity(sourced.count)
        for record in sourced where Self.isIndexable(record.vector, dimension: dimension) {
            indexable.append(record)
        }
        try await rebuild(indexable, ceiling: .standard)
        return true
    }

    public func upsert(id: UUID, vector: [Float]) async throws {
        guard !rebuilding else {
            throw ProximaVectorIndexError.busy
        }
        try Self.validate(vector, dimension: dimension)
        do {
            try await index.add(Vector(vector), id: id)
            records[id] = vector
        } catch {
            throw ProximaVectorIndexError.candidateFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(id: UUID) async throws -> Bool {
        guard !rebuilding else {
            throw ProximaVectorIndexError.busy
        }
        let removed = await index.remove(id: id)
        if removed { records.removeValue(forKey: id) }
        return removed
    }

    public func search(_ query: ArchonMemory.VectorIndexQuery) async throws -> [ArchonMemory.VectorIndexMatch] {
        try Self.validate(query.vector, dimension: dimension)
        guard (0...500).contains(query.limit) else {
            throw ArchonMemory.VectorIndexError.invalidLimit(query.limit)
        }
        guard query.limit > 0 else { return [] }
        if let allowedIDs = query.allowedIDs, allowedIDs.isEmpty {
            return []
        }

        let filter: (@Sendable (UUID) -> Bool)?
        var fetchLimit = query.limit
        var queryWidth = configuration.querySearchWidth
        if let allowedIDs = query.allowedIDs {
            filter = { id in allowedIDs.contains(id) }
            // Narrow allow-lists starve ANN traversal: overfetch
            // proportionally to the inverse selectivity, then trim after
            // exact ranking. The allow-list is never broadened.
            fetchLimit = ArchonMemory.LocalVectorStore.filteredOverfetchLimit(
                baseLimit: query.limit,
                allowedCount: allowedIDs.count,
                totalCount: max(records.count, allowedIDs.count)
            )
            queryWidth = max(queryWidth, fetchLimit)
        } else {
            filter = nil
        }
        let candidateVector = Vector(query.vector)
        let results = await index.search(
            query: candidateVector,
            k: fetchLimit,
            efSearch: queryWidth,
            filter: filter
        )

        return results
            .map {
                ArchonMemory.VectorIndexMatch(
                    id: $0.id,
                    similarity: max(-1, min(1, 1 - $0.distance))
                )
            }
            .sorted {
                if $0.similarity != $1.similarity {
                    return $0.similarity > $1.similarity
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(query.limit)
            .map { $0 }
    }

    private static func isIndexable(_ vector: [Float], dimension: Int) -> Bool {
        !vector.isEmpty && vector.count == dimension && vector.allSatisfy(\.isFinite)
    }

    private static func encodedSnapshot(
        dimension: Int,
        configuration: ProximaVectorIndexConfiguration,
        records: [ArchonMemory.VectorIndexRecord]
    ) throws -> Data {
        let snapshot = ProximaVectorIndexSnapshot(
            dimension: dimension,
            configuration: configuration,
            records: records.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        return try JSONEncoder().encode(snapshot)
    }

    private static func validate(
        _ vector: [Float],
        dimension: Int
    ) throws {
        guard !vector.isEmpty else {
            throw ArchonMemory.VectorIndexError.emptyVector
        }
        guard vector.count == dimension else {
            throw ArchonMemory.VectorIndexError.invalidDimension(
                expected: dimension,
                actual: vector.count
            )
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw ArchonMemory.VectorIndexError.nonFiniteComponent
        }
    }

    private static func validate(
        _ configuration: ProximaVectorIndexConfiguration
    ) throws {
        guard configuration.maximumConnections >= 2 else {
            throw ProximaVectorIndexError.invalidConfiguration(
                "maximumConnections must be at least 2"
            )
        }
        guard configuration.maximumConnections <= Int.max / 2 else {
            throw ProximaVectorIndexError.invalidConfiguration(
                "maximumConnections is too large"
            )
        }
        guard configuration.constructionSearchWidth > 0 else {
            throw ProximaVectorIndexError.invalidConfiguration(
                "constructionSearchWidth must be positive"
            )
        }
        guard configuration.querySearchWidth > 0 else {
            throw ProximaVectorIndexError.invalidConfiguration(
                "querySearchWidth must be positive"
            )
        }
    }
}
