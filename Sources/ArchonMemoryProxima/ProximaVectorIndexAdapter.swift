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
        }
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
        get async {
            await index.liveCount
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
        } catch let error as ArchonMemory.VectorIndexError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProximaVectorIndexError.candidateFailure(error.localizedDescription)
        }
    }

    public func upsert(id: UUID, vector: [Float]) async throws {
        guard !rebuilding else {
            throw ProximaVectorIndexError.busy
        }
        try Self.validate(vector, dimension: dimension)
        do {
            try await index.add(Vector(vector), id: id)
        } catch {
            throw ProximaVectorIndexError.candidateFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(id: UUID) async throws -> Bool {
        guard !rebuilding else {
            throw ProximaVectorIndexError.busy
        }
        return await index.remove(id: id)
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
        if let allowedIDs = query.allowedIDs {
            filter = { id in allowedIDs.contains(id) }
        } else {
            filter = nil
        }
        let candidateVector = Vector(query.vector)
        let queryWidth = configuration.querySearchWidth
        let results = await index.search(
            query: candidateVector,
            k: query.limit,
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
