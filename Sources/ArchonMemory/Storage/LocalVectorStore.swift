import Foundation
import GRDB
import Accelerate

/// Concrete local database store backed by SQLite (via GRDB) and Accelerate framework SIMD vector operations.
/// Supports Core Memories, Knowledge Graph, Documents/Bookmarks (Supermemory), Recall Dialogue Logs (Letta), and Summaries (Zep).
public actor LocalVectorStore: VectorStore {
    private static let maximumVectorDimensions = 16_384
    private static let maximumMetadataBytes = 1 * 1024 * 1024
    private let dbQueue: DatabaseQueue
    private let alpha: Float // Vector similarity weight (default 0.7)
    private let beta: Float  // BM25 text rank weight (default 0.3)
    private let decayLambda: Float // Time decay factor (per day, default 0.01)

    public init(
        databasePath: String? = nil,
        alpha: Float = 0.7,
        beta: Float = 0.3,
        decayLambda: Float = 0.01
    ) throws {
        self.alpha = alpha
        self.beta = beta
        self.decayLambda = decayLambda
        
        let path: String
        if let databasePath = databasePath {
            path = databasePath
        } else {
            let fileManager = FileManager.default
            let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            let appSupportDir = urls.first ?? fileManager.temporaryDirectory
            let archonDir = appSupportDir.appendingPathComponent("ArchonMemory", isDirectory: true)
            try fileManager.createDirectory(at: archonDir, withIntermediateDirectories: true)
            path = archonDir.appendingPathComponent("archon.sqlite").path
        }
        
        self.dbQueue = try DatabaseQueue(path: path)
        try Self.setupSchema(dbQueue: dbQueue)
    }

    /// In-memory database initializer for testing.
    public init(inMemory: Bool, alpha: Float = 0.7, beta: Float = 0.3, decayLambda: Float = 0.01) throws {
        self.alpha = alpha
        self.beta = beta
        self.decayLambda = decayLambda
        self.dbQueue = try DatabaseQueue()
        try Self.setupSchema(dbQueue: dbQueue)
    }

    private static func setupSchema(dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1_create_tables") { db in
            // Primary Memories Table
            try db.create(table: "memories") { t in
                t.column("id", .text).primaryKey()
                t.column("memory", .text).notNull()
                t.column("hash", .text).notNull()
                t.column("vectorData", .blob)
                t.column("userId", .text)
                t.column("agentId", .text)
                t.column("runId", .text)
                t.column("metadataJson", .text)
                t.column("validFrom", .double).notNull()
                t.column("validTo", .double)
                t.column("supersededById", .text)
                t.column("accessCount", .integer).notNull().defaults(to: 0)
                t.column("lastAccessedAt", .double).notNull()
                t.column("scoreWeight", .double).notNull().defaults(to: 1.0)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("syncState", .text).notNull().defaults(to: "pendingUpload")
            }
            
            // FTS5 Virtual Table for BM25 text search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                    id UNINDEXED,
                    memory,
                    tokenize = 'porter unicode61'
                );
            """)
            
            // Audit History Table
            try db.create(table: "memory_history") { t in
                t.column("id", .text).primaryKey()
                t.column("memoryId", .text).notNull()
                t.column("action", .text).notNull()
                t.column("oldMemory", .text)
                t.column("newMemory", .text)
                t.column("timestamp", .double).notNull()
                t.column("userId", .text)
            }
            
            // Core Working Memory Blocks Table
            try db.create(table: "core_memory_blocks") { t in
                t.column("blockKey", .text).primaryKey()
                t.column("blockValue", .text).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }

        migrator.registerMigration("v2_add_supermemory_and_zep_tables") { db in
            // Documents & Bookmarks Table (Supermemory)
            try db.create(table: "documents") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("url", .text)
                t.column("content", .text).notNull()
                t.column("chunkIndex", .integer).notNull().defaults(to: 0)
                t.column("totalChunks", .integer).notNull().defaults(to: 1)
                t.column("vectorData", .blob)
                t.column("tagsJson", .text)
                t.column("userId", .text)
                t.column("metadataJson", .text)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }

            // Recall Message Log Table (Letta/MemGPT)
            try db.create(table: "recall_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("userId", .text)
                t.column("agentId", .text)
                t.column("runId", .text)
                t.column("timestamp", .double).notNull()
            }

            // Conversation Summaries Table (Zep)
            try db.create(table: "conversation_summaries") { t in
                t.column("id", .text).primaryKey()
                t.column("userId", .text)
                t.column("agentId", .text)
                t.column("runId", .text)
                t.column("summary", .text).notNull()
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("lastMessageTimestamp", .double).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }

        migrator.registerMigration("v3_scope_core_memory_blocks") { db in
            // v1 used blockKey as a global primary key. Rebuild the table with an
            // explicit user scope so two users can safely use the same block names.
            try db.execute(sql: "ALTER TABLE core_memory_blocks RENAME TO core_memory_blocks_legacy")
            try db.execute(sql: """
                CREATE TABLE core_memory_blocks (
                    blockKey TEXT NOT NULL,
                    userId TEXT NOT NULL,
                    blockValue TEXT NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    PRIMARY KEY (blockKey, userId)
                )
                """)
            try db.execute(sql: """
                INSERT INTO core_memory_blocks (blockKey, userId, blockValue, updatedAt)
                SELECT blockKey, '', blockValue, updatedAt FROM core_memory_blocks_legacy
                """)
            try db.drop(table: "core_memory_blocks_legacy")
        }

        migrator.registerMigration("v4_add_memory_feedback") { db in
            try db.create(table: "memory_feedback") { t in
                t.column("id", .text).primaryKey()
                t.column("insightID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("userId", .text)
                t.column("timestamp", .double).notNull()
                t.column("metadataJson", .text)
            }
            try db.create(index: "memory_feedback_insight_timestamp", on: "memory_feedback", columns: ["insightID", "timestamp"])
        }
        
        try migrator.migrate(dbQueue)
    }

    // MARK: - VectorStore Implementation

    public func save(item: MemoryItem) async throws {
        try await saveBatch(items: [item])
    }

    public func saveBatch(items: [MemoryItem]) async throws {
        try await dbQueue.write { db in
            for item in items {
                try Self.validate(vector: item.vector, label: "memory")
                let vectorData = Data(bytes: item.vector, count: item.vector.count * MemoryLayout<Float>.size)
                let metadataData = try JSONEncoder().encode(item.metadata)
                guard metadataData.count <= Self.maximumMetadataBytes else {
                    throw ArchonMemoryError.inputTooLarge(maxBytes: Self.maximumMetadataBytes)
                }
                let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

                try db.execute(
                    sql: """
                    INSERT INTO memories (
                        id, memory, hash, vectorData, userId, agentId, runId, metadataJson,
                        validFrom, validTo, supersededById, accessCount, lastAccessedAt,
                        scoreWeight, createdAt, updatedAt, isDeleted, version, syncState
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?
                    ) ON CONFLICT(id) DO UPDATE SET
                        memory = excluded.memory,
                        hash = excluded.hash,
                        vectorData = excluded.vectorData,
                        userId = excluded.userId,
                        agentId = excluded.agentId,
                        runId = excluded.runId,
                        metadataJson = excluded.metadataJson,
                        validFrom = excluded.validFrom,
                        validTo = excluded.validTo,
                        supersededById = excluded.supersededById,
                        accessCount = excluded.accessCount,
                        lastAccessedAt = excluded.lastAccessedAt,
                        scoreWeight = excluded.scoreWeight,
                        updatedAt = excluded.updatedAt,
                        isDeleted = excluded.isDeleted,
                        version = excluded.version,
                        syncState = excluded.syncState
                    """,
                    arguments: [
                        item.id.uuidString,
                        item.memory,
                        item.hash,
                        vectorData,
                        item.userId,
                        item.agentId,
                        item.runId,
                        metadataJson,
                        item.validFrom.timeIntervalSince1970,
                        item.validTo?.timeIntervalSince1970,
                        item.supersededById?.uuidString,
                        item.accessCount,
                        item.lastAccessedAt.timeIntervalSince1970,
                        item.scoreWeight,
                        item.createdAt.timeIntervalSince1970,
                        item.updatedAt.timeIntervalSince1970,
                        item.isDeleted,
                        item.version,
                        "pendingUpload"
                    ]
                )
                
                // Update FTS5 index
                try db.execute(sql: "DELETE FROM memories_fts WHERE id = ?", arguments: [item.id.uuidString])
                if !item.isDeleted {
                    try db.execute(
                        sql: "INSERT INTO memories_fts (id, memory) VALUES (?, ?)",
                        arguments: [item.id.uuidString, item.memory]
                    )
                }
            }
        }
        markScoringBlocksDirty()
        if vectorCacheWarmed {
            for item in items {
                // The cache mirrors non-deleted rows only; a save that marks
                // a row deleted evicts it, matching the SQL filter truth.
                guard !item.isDeleted else {
                    vectorCache[item.id] = nil
                    continue
                }
                vectorCache[item.id] = CachedScoringVector(
                    vector: item.vector,
                    lastAccessedAt: item.lastAccessedAt.timeIntervalSince1970,
                    scoreWeight: item.scoreWeight,
                    validFrom: item.validFrom.timeIntervalSince1970,
                    validTo: item.validTo?.timeIntervalSince1970
                )
            }
        }
    }

    public func fetch(id: UUID) async throws -> MemoryItem? {
        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try Self.rowToMemoryItem(row)
        }
    }

    public func fetchAll(filters: MemoryFilter?, limit: Int? = nil, offset: Int? = nil) async throws -> [MemoryItem] {
        if let limit, !(0...500).contains(limit) {
            throw ArchonMemoryError.invalidSearchRequest("memory limit must be between 0 and 500")
        }
        if let offset, offset < 0 {
            throw ArchonMemoryError.invalidSearchRequest("offset must be non-negative")
        }
        let filtersMetadata = filters?.metadata?.isEmpty == false
        let items = try await dbQueue.read { db in
            var sql = "SELECT * FROM memories WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            
            Self.appendFilterConditions(filters: filters, sql: &sql, args: &args)
            sql += " ORDER BY createdAt DESC"
            
            // Metadata is stored as a portable JSON blob rather than relying on
            // SQLite's optional JSON1 extension. Apply limit/offset after the
            // in-memory metadata predicate so pagination remains correct.
            if !filtersMetadata, let limit = limit {
                sql += " LIMIT \(limit)"
                if let offset = offset {
                    sql += " OFFSET \(offset)"
                }
            }
            
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map { try Self.rowToMemoryItem($0) }
        }

        guard let requiredMetadata = filters?.metadata, !requiredMetadata.isEmpty else {
            return items
        }

        let matchingItems = items.filter { item in
            requiredMetadata.allSatisfy { key, value in
                item.metadata[key] == value
            }
        }
        guard let limit else { return matchingItems }

        let start = max(offset ?? 0, 0)
        let count = max(limit, 0)
        return Array(matchingItems.dropFirst(start).prefix(count))
    }

    public func delete(id: UUID) async throws {
        try await dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                UPDATE memories
                SET isDeleted = 1, syncState = 'pendingUpload', updatedAt = ?
                WHERE id = ?
                """,
                arguments: [now, id.uuidString]
            )
            try db.execute(sql: "DELETE FROM memories_fts WHERE id = ?", arguments: [id.uuidString])
        }
        vectorCache[id] = nil
        markScoringBlocksDirty()
    }

    public func deleteAll(userId: String?, agentId: String?, runId: String?) async throws {
        try await dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            var predicates = ["1=1"]
            var scopeArgs: [DatabaseValueConvertible] = []
            
            if let userId = userId {
                predicates.append("userId = ?")
                scopeArgs.append(userId)
            }
            if let agentId = agentId {
                predicates.append("agentId = ?")
                scopeArgs.append(agentId)
            }
            if let runId = runId {
                predicates.append("runId = ?")
                scopeArgs.append(runId)
            }
            
            let predicate = predicates.joined(separator: " AND ")
            var updateArgs: [DatabaseValueConvertible] = [now]
            updateArgs.append(contentsOf: scopeArgs)
            try db.execute(
                sql: "UPDATE memories SET isDeleted = 1, syncState = 'pendingUpload', updatedAt = ? WHERE \(predicate)",
                arguments: StatementArguments(updateArgs)
            )

            // Delete only the FTS rows belonging to the same scope. Clearing
            // the whole virtual table would make another user's memories
            // temporarily unsearchable after a scoped delete.
            try db.execute(
                sql: "DELETE FROM memories_fts WHERE id IN (SELECT id FROM memories WHERE \(predicate))",
                arguments: StatementArguments(scopeArgs)
            )
        }
        vectorCache.removeAll()
        vectorCacheWarmed = false
        markScoringBlocksDirty()
    }

    public func reset() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memories")
            try db.execute(sql: "DELETE FROM memories_fts")
            try db.execute(sql: "DELETE FROM memory_history")
            try db.execute(sql: "DELETE FROM core_memory_blocks")
            try db.execute(sql: "DELETE FROM documents")
            try db.execute(sql: "DELETE FROM recall_messages")
            try db.execute(sql: "DELETE FROM conversation_summaries")
            try db.execute(sql: "DELETE FROM memory_feedback")
        }
        vectorCache.removeAll()
        vectorCacheWarmed = false
        markScoringBlocksDirty()
    }

    /// Lean scoring row: only the columns ranking needs. Full items are
    /// materialized solely for the trimmed top-K, keeping large-corpus
    /// search proportional to K instead of N.
    private struct SearchCandidate: Sendable {
        let id: UUID
        let vector: [Float]
        let lastAccessedAt: Double
        let scoreWeight: Float
    }

    /// In-RAM mirror of the scoring columns. Filter truth stays in SQL (the
    /// candidate ID set always comes from a filtered query); this cache only
    /// avoids re-reading vectors per search. Write-through on every memories
    /// mutation, so it can never disagree with the database. Footprint is
    /// roughly 4 bytes per stored float plus dictionary overhead.
    private struct CachedScoringVector: Sendable {
        var vector: [Float]
        var lastAccessedAt: Double
        var scoreWeight: Float
        var validFrom: Double
        var validTo: Double?
    }

    private var vectorCache: [UUID: CachedScoringVector] = [:]
    private var vectorCacheWarmed = false

    /// Packed scoring block for one vector dimension: row-major matrix plus
    /// precomputed squared norms, so a query needs one multiply instead of a
    /// pack plus three reductions. Rebuilt lazily after vector-affecting
    /// mutations only; access touches never dirty it.
    private struct ScoringBlock: Sendable {
        var ids: [UUID] = []
        var flat: [Float] = []
        var normsSquared: [Float] = []
        var accessed: [Double] = []
        var weights: [Float] = []
        var validFrom: [Double] = []
        var validTo: [Double?] = []
        var dimensions: Int = 0
    }

    private var scoringBlocks: [Int: ScoringBlock] = [:]
    private var blockPositions: [UUID: (dimensions: Int, index: Int)] = [:]
    private var emptyVectorIDs: Set<UUID> = []
    private var scoringBlocksDirty = true

    private func markScoringBlocksDirty() {
        scoringBlocksDirty = true
    }

    private func rebuildScoringBlocksIfNeeded() {
        guard scoringBlocksDirty else { return }
        var blocks: [Int: ScoringBlock] = [:]
        var positions: [UUID: (dimensions: Int, index: Int)] = [:]
        var emptyIDs = Set<UUID>()
        for (id, cached) in vectorCache {
            let dimensions = cached.vector.count
            guard dimensions > 0 else {
                emptyIDs.insert(id)
                continue
            }
            var block = blocks[dimensions] ?? ScoringBlock(dimensions: dimensions)
            positions[id] = (dimensions, block.ids.count)
            block.ids.append(id)
            block.flat.append(contentsOf: cached.vector)
            block.accessed.append(cached.lastAccessedAt)
            block.weights.append(cached.scoreWeight)
            block.validFrom.append(cached.validFrom)
            block.validTo.append(cached.validTo)
            blocks[dimensions] = block
        }
        for dimensions in blocks.keys {
            guard var block = blocks[dimensions] else { continue }
            var squares = [Float](repeating: 0, count: block.flat.count)
            vDSP_vsq(block.flat, 1, &squares, 1, vDSP_Length(block.flat.count))
            let ones = [Float](repeating: 1, count: dimensions)
            var norms = [Float](repeating: 0, count: block.ids.count)
            squares.withUnsafeBufferPointer { squarePointer in
                ones.withUnsafeBufferPointer { onePointer in
                    norms.withUnsafeMutableBufferPointer { normPointer in
                        guard let a = squarePointer.baseAddress,
                              let b = onePointer.baseAddress,
                              let c = normPointer.baseAddress else { return }
                        vDSP_mmul(
                            a, 1, b, 1, c, 1,
                            vDSP_Length(block.ids.count), 1, vDSP_Length(dimensions)
                        )
                    }
                }
            }
            block.normsSquared = norms
            blocks[dimensions] = block
        }
        scoringBlocks = blocks
        blockPositions = positions
        emptyVectorIDs = emptyIDs
        scoringBlocksDirty = false
    }

    private func warmVectorCacheIfNeeded() async throws {
        guard !vectorCacheWarmed else { return }
        let snapshot = try await dbQueue.read { db -> [UUID: CachedScoringVector] in
            let rows = try Row.fetchAll(db, sql: "SELECT id, vectorData, lastAccessedAt, scoreWeight, validFrom, validTo FROM memories WHERE isDeleted = 0")
            var snapshot: [UUID: CachedScoringVector] = [:]
            for row in rows {
                let idString: String = row["id"]
                let id = UUID(uuidString: idString) ?? UUID()
                var vector: [Float] = []
                if let blob: Data = row["vectorData"] {
                    guard blob.count % MemoryLayout<Float>.size == 0 else {
                        throw ArchonMemoryError.invalidConfiguration("Stored memory vector has an invalid byte length.")
                    }
                    vector = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    try Self.validate(vector: vector, label: "stored memory")
                }
                let accessed: Double = row["lastAccessedAt"]
                let validFrom: Double = row["validFrom"]
                let validTo: Double? = row["validTo"]
                snapshot[id] = CachedScoringVector(
                    vector: vector,
                    lastAccessedAt: accessed,
                    scoreWeight: Float(row["scoreWeight"] as Double),
                    validFrom: validFrom,
                    validTo: validTo
                )
            }
            return snapshot
        }
        vectorCache = snapshot
        vectorCacheWarmed = true
    }

    /// True when the filter is the default active/non-deleted shape, so the
    /// candidate set can be evaluated from the cache without a SQL round
    /// trip. Any scope, metadata, or deleted-inclusion predicate takes the
    /// SQL path, keeping filter truth in exactly one place per shape.
    private static func isDefaultActiveFilter(_ filters: MemoryFilter) -> Bool {
        filters.userId == nil
            && filters.agentId == nil
            && filters.runId == nil
            && (filters.metadata?.isEmpty ?? true)
            && !filters.includeDeleted
    }

    private func fetchSearchCandidates(filters: MemoryFilter) async throws -> [SearchCandidate] {
        try await warmVectorCacheIfNeeded()
        if Self.isDefaultActiveFilter(filters) {
            let activeAt = filters.activeAt?.timeIntervalSince1970
            return vectorCache.compactMap { id, cached in
                // Mirrors the SQL temporal predicate exactly: validFrom <=
                // activeAt AND (validTo IS NULL OR validTo > activeAt).
                if let activeAt {
                    let inWindow = cached.validFrom <= activeAt
                        && (cached.validTo.map { $0 > activeAt } ?? true)
                    guard inWindow else { return nil }
                }
                return SearchCandidate(
                    id: id,
                    vector: cached.vector,
                    lastAccessedAt: cached.lastAccessedAt,
                    scoreWeight: cached.scoreWeight
                )
            }
        }
        let requiredMetadata: [String: String]? =
            filters.metadata?.isEmpty == false ? filters.metadata : nil
        let matchingIDs = try await dbQueue.read { db -> [UUID] in
            var sql = "SELECT id"
            if requiredMetadata != nil {
                sql += ", metadataJson"
            }
            sql += " FROM memories WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            Self.appendFilterConditions(filters: filters, sql: &sql, args: &args)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.compactMap { row -> UUID? in
                let idString: String = row["id"]
                let id = UUID(uuidString: idString) ?? UUID()
                if let requiredMetadata {
                    var metadata: [String: String] = [:]
                    if let json: String = row["metadataJson"],
                       let data = json.data(using: .utf8) {
                        guard data.count <= Self.maximumMetadataBytes else {
                            throw ArchonMemoryError.inputTooLarge(maxBytes: Self.maximumMetadataBytes)
                        }
                        metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                    }
                    guard requiredMetadata.allSatisfy({ metadata[$0.key] == $0.value }) else {
                        return nil
                    }
                }
                return id
            }
        }
        var candidates: [SearchCandidate] = []
        candidates.reserveCapacity(matchingIDs.count)
        for id in matchingIDs {
            if let cached = vectorCache[id] {
                candidates.append(SearchCandidate(
                    id: id,
                    vector: cached.vector,
                    lastAccessedAt: cached.lastAccessedAt,
                    scoreWeight: cached.scoreWeight
                ))
            } else if let item = try await fetch(id: id) {
                // Defensive: write-through keeps the cache complete, so this
                // only runs for rows created outside the mutation funnel.
                vectorCache[id] = CachedScoringVector(
                    vector: item.vector,
                    lastAccessedAt: item.lastAccessedAt.timeIntervalSince1970,
                    scoreWeight: item.scoreWeight,
                    validFrom: item.validFrom.timeIntervalSince1970,
                    validTo: item.validTo?.timeIntervalSince1970
                )
                candidates.append(SearchCandidate(
                    id: id,
                    vector: item.vector,
                    lastAccessedAt: item.lastAccessedAt.timeIntervalSince1970,
                    scoreWeight: item.scoreWeight
                ))
            }
        }
        return candidates
    }

    private func fetchRankedItems(ids: [UUID]) async throws -> [UUID: MemoryItem] {
        guard !ids.isEmpty else { return [:] }
        return try await dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map { $0.uuidString })
            )
            var items: [UUID: MemoryItem] = [:]
            for row in rows {
                let item = try Self.rowToMemoryItem(row)
                items[item.id] = item
            }
            return items
        }
    }

    public func search(
        query: String?,
        vector: [Float]?,
        limit: Int,
        filters: MemoryFilter?
    ) async throws -> [SearchResult] {
        guard (0...500).contains(limit) else {
            throw ArchonMemoryError.invalidSearchRequest("limit must be between 0 and 500")
        }
        if let query, query.utf8.count > Self.maximumMetadataBytes {
            throw ArchonMemoryError.invalidSearchRequest("query is too large")
        }
        if let vector {
            try Self.validate(vector: vector, label: "query")
        }
        // Retrieval never returns deleted or expired facts by default. A nil
        // filter means "active, non-deleted" rather than "unfiltered"; callers
        // opt out explicitly with includeDeleted or activeAt: nil.
        let effectiveFilters = filters ?? MemoryFilter()
        if let queryVector = vector, !queryVector.isEmpty,
           Self.isDefaultActiveFilter(effectiveFilters) {
            return try await searchDefaultVector(
                query: query,
                vector: queryVector,
                limit: limit,
                filters: effectiveFilters
            )
        }
        let candidates = try await fetchSearchCandidates(filters: effectiveFilters)
        guard !candidates.isEmpty else { return [] }
        
        let textScores = try await fetchTextScores(query: query)

        let now = Date().timeIntervalSince1970

        // One batched scoring pass replaces N per-row vDSP triples. Rows with
        // empty vectors keep a nil similarity, exactly as before; dimension
        // mismatches score 0.0 through the shared batch guard.
        var vectorSimilarities = [Float?](repeating: nil, count: candidates.count)
        if let queryVector = vector, !queryVector.isEmpty {
            let batch = VectorMath.batchCosineSimilarities(
                query: queryVector,
                rows: candidates.map(\.vector)
            )
            for index in candidates.indices where !candidates[index].vector.isEmpty {
                vectorSimilarities[index] = batch[index]
            }
        }

        var rankedIDs: [(id: UUID, score: Float, vectorSimilarity: Float?, textRank: Float)] = []
        rankedIDs.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            let similarity = vectorSimilarities[index]
            let textRank = textScores[candidate.id] ?? 0.0
            let vScore = similarity ?? 0.0

            let ageInDays = Float(max(0, now - candidate.lastAccessedAt) / 86400.0)
            let timeDecay = exp(-decayLambda * ageInDays)

            let finalScore = (alpha * vScore + beta * textRank * timeDecay) * candidate.scoreWeight

            if finalScore > 0 || vector == nil {
                rankedIDs.append((
                    id: candidate.id,
                    score: finalScore,
                    vectorSimilarity: similarity,
                    textRank: textRank
                ))
            }
        }

        rankedIDs.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let trimmed = Array(rankedIDs.prefix(limit))
        guard !trimmed.isEmpty else { return [] }

        let itemsByID = try await fetchRankedItems(ids: trimmed.map(\.id))
        var results: [SearchResult] = []
        results.reserveCapacity(trimmed.count)
        for entry in trimmed {
            // A row deleted between the scoring read and this read is
            // skipped: never return a fact that no longer exists.
            guard let item = itemsByID[entry.id] else { continue }
            results.append(SearchResult(
                item: item,
                score: entry.score,
                vectorSimilarity: entry.vectorSimilarity,
                textRank: entry.textRank
            ))
        }

        if !results.isEmpty {
            try await touchAccessed(ids: results.map { $0.item.id })
        }

        return results
    }

    private func touchAccessed(ids: [UUID]) async throws {
        let touchTime = Date().timeIntervalSince1970
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try await dbQueue.write { db in
            var arguments: [DatabaseValueConvertible] = [touchTime]
            arguments.append(contentsOf: ids.map { $0.uuidString })
            try db.execute(
                sql: "UPDATE memories SET accessCount = accessCount + 1, lastAccessedAt = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }
        for id in ids {
            vectorCache[id]?.lastAccessedAt = touchTime
            if let position = blockPositions[id] {
                scoringBlocks[position.dimensions]?.accessed[position.index] = touchTime
            }
        }
    }

    private struct RankedEntry: Sendable {
        let id: UUID
        let score: Float
        let vectorSimilarity: Float?
        let textRank: Float
    }

    private func fetchTextScores(query: String?) async throws -> [UUID: Float] {
        var textScores: [UUID: Float] = [:]
        if let query = query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ftsResults = try await dbQueue.read { db -> [Row] in
                let sanitizedQuery = query.replacingOccurrences(of: "\"", with: "")
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, rank FROM memories_fts
                    WHERE memories_fts MATCH ?
                    ORDER BY rank ASC
                    """,
                    arguments: ["\"\(sanitizedQuery)\"*"]
                )
            }

            for row in ftsResults {
                if let idString: String = row["id"], let id = UUID(uuidString: idString), let rank: Double = row["rank"] {
                    let normalizedRank = Float(1.0 / (1.0 + abs(rank)))
                    textScores[id] = normalizedRank
                }
            }
        }
        return textScores
    }

    /// Default-filter vector search over the packed score blocks: one matrix
    /// multiply per query plus cached norms, with per-row metadata resolved
    /// from the write-through cache.
    private func searchDefaultVector(
        query: String?,
        vector queryVector: [Float],
        limit: Int,
        filters: MemoryFilter
    ) async throws -> [SearchResult] {
        try await warmVectorCacheIfNeeded()
        rebuildScoringBlocksIfNeeded()
        guard !vectorCache.isEmpty else { return [] }

        let textScores = try await fetchTextScores(query: query)
        let now = Date().timeIntervalSince1970
        let activeAt = filters.activeAt?.timeIntervalSince1970

        var queryNormSquared: Float = 0
        vDSP_svesq(queryVector, 1, &queryNormSquared, vDSP_Length(queryVector.count))
        let queryNorm = sqrt(queryNormSquared)

        var matchingDots: [Float] = []
        if let block = scoringBlocks[queryVector.count], !block.ids.isEmpty {
            var dots = [Float](repeating: 0, count: block.ids.count)
            block.flat.withUnsafeBufferPointer { flatPointer in
                queryVector.withUnsafeBufferPointer { queryPointer in
                    dots.withUnsafeMutableBufferPointer { dotPointer in
                        guard let a = flatPointer.baseAddress,
                              let b = queryPointer.baseAddress,
                              let c = dotPointer.baseAddress else { return }
                        vDSP_mmul(
                            a, 1, b, 1, c, 1,
                            vDSP_Length(block.ids.count), 1, vDSP_Length(block.dimensions)
                        )
                    }
                }
            }
            matchingDots = dots
        }

        var ranked: [RankedEntry] = []
        ranked.reserveCapacity(vectorCache.count)
        for block in scoringBlocks.values {
            let isMatchingBlock = block.dimensions == queryVector.count
            for position in block.ids.indices {
                if let activeAt {
                    let inWindow = block.validFrom[position] <= activeAt
                        && (block.validTo[position].map { $0 > activeAt } ?? true)
                    guard inWindow else { continue }
                }
                let similarity: Float
                if isMatchingBlock {
                    let denominator = queryNorm * sqrt(block.normsSquared[position])
                    if denominator.isFinite, denominator > 0 {
                        let raw = matchingDots[position] / denominator
                        similarity = raw.isFinite ? min(max(raw, -1), 1) : 0
                    } else {
                        similarity = 0
                    }
                } else {
                    similarity = 0
                }
                let id = block.ids[position]
                let textRank = textScores[id] ?? 0.0

                let ageInDays = Float(max(0, now - block.accessed[position]) / 86400.0)
                let timeDecay = exp(-decayLambda * ageInDays)

                let finalScore = (alpha * similarity + beta * textRank * timeDecay) * block.weights[position]
                if finalScore > 0 {
                    ranked.append(RankedEntry(
                        id: id,
                        score: finalScore,
                        vectorSimilarity: similarity,
                        textRank: textRank
                    ))
                }
            }
        }
        for id in emptyVectorIDs {
            guard let cached = vectorCache[id] else { continue }
            if let activeAt {
                let inWindow = cached.validFrom <= activeAt
                    && (cached.validTo.map { $0 > activeAt } ?? true)
                guard inWindow else { continue }
            }
            let textRank = textScores[id] ?? 0.0
            let ageInDays = Float(max(0, now - cached.lastAccessedAt) / 86400.0)
            let timeDecay = exp(-decayLambda * ageInDays)
            let finalScore = (beta * textRank * timeDecay) * cached.scoreWeight
            if finalScore > 0 {
                ranked.append(RankedEntry(
                    id: id,
                    score: finalScore,
                    vectorSimilarity: nil,
                    textRank: textRank
                ))
            }
        }

        return try await materialize(ranked: ranked, limit: limit)
    }

    private func materialize(ranked: [RankedEntry], limit: Int) async throws -> [SearchResult] {
        let ordered = ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.uuidString < $1.id.uuidString
        }
        let trimmed = Array(ordered.prefix(limit))
        guard !trimmed.isEmpty else { return [] }

        let itemsByID = try await fetchRankedItems(ids: trimmed.map(\.id))
        var results: [SearchResult] = []
        results.reserveCapacity(trimmed.count)
        for entry in trimmed {
            // A row deleted between the scoring read and this read is
            // skipped: never return a fact that no longer exists.
            guard let item = itemsByID[entry.id] else { continue }
            results.append(SearchResult(
                item: item,
                score: entry.score,
                vectorSimilarity: entry.vectorSimilarity,
                textRank: entry.textRank
            ))
        }

        if !results.isEmpty {
            try await touchAccessed(ids: results.map { $0.item.id })
        }

        return results
    }

    // MARK: - Documents & Bookmarks (Supermemory)

    public func saveDocument(doc: DocumentItem) async throws {
        try await dbQueue.write { db in
            try Self.validate(vector: doc.vector, label: "document")
            let vectorData = Data(bytes: doc.vector, count: doc.vector.count * MemoryLayout<Float>.size)
            let tagsData = try JSONEncoder().encode(doc.tags)
            let tagsJson = String(data: tagsData, encoding: .utf8) ?? "[]"
            let metadataData = try JSONEncoder().encode(doc.metadata)
            guard tagsData.count <= Self.maximumMetadataBytes,
                  metadataData.count <= Self.maximumMetadataBytes else {
                throw ArchonMemoryError.inputTooLarge(maxBytes: Self.maximumMetadataBytes)
            }
            let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

            try db.execute(
                sql: """
                INSERT INTO documents (
                    id, title, url, content, chunkIndex, totalChunks, vectorData,
                    tagsJson, userId, metadataJson, createdAt, updatedAt, isDeleted
                ) VALUES (
                    ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?
                ) ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    url = excluded.url,
                    content = excluded.content,
                    vectorData = excluded.vectorData,
                    tagsJson = excluded.tagsJson,
                    metadataJson = excluded.metadataJson,
                    updatedAt = excluded.updatedAt,
                    isDeleted = excluded.isDeleted
                """,
                arguments: [
                    doc.id.uuidString,
                    doc.title,
                    doc.url,
                    doc.content,
                    doc.chunkIndex,
                    doc.totalChunks,
                    vectorData,
                    tagsJson,
                    doc.userId,
                    metadataJson,
                    doc.createdAt.timeIntervalSince1970,
                    doc.updatedAt.timeIntervalSince1970,
                    doc.isDeleted
                ]
            )
        }
    }

    public func fetchAllDocuments(userId: String? = nil) async throws -> [DocumentItem] {
        try await dbQueue.read { db in
            var sql = "SELECT * FROM documents WHERE isDeleted = 0"
            var args: [DatabaseValueConvertible] = []
            if let userId {
                sql += " AND userId = ?"
                args.append(userId)
            }
            sql += " ORDER BY updatedAt ASC, id ASC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map { try Self.rowToDocumentItem($0) }
        }
    }

    private static func validate(vector: [Float], label: String) throws {
        guard vector.count <= maximumVectorDimensions,
              vector.allSatisfy(\.isFinite) else {
            throw ArchonMemoryError.invalidSearchRequest(
                "\(label) vector must contain at most \(maximumVectorDimensions) finite values"
            )
        }
    }

    public func searchDocuments(query: String?, vector: [Float]?, limit: Int, userId: String?) async throws -> [DocumentItem] {
        guard (0...500).contains(limit) else {
            throw ArchonMemoryError.invalidSearchRequest("document limit must be between 0 and 500")
        }
        if let query, query.utf8.count > Self.maximumMetadataBytes {
            throw ArchonMemoryError.invalidSearchRequest("document query is too large")
        }
        if let vector {
            try Self.validate(vector: vector, label: "document query")
        }
        guard limit > 0 else { return [] }

        let docs = try await fetchAllDocuments(userId: userId)
        guard !docs.isEmpty else { return [] }

        let terms = (query ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }

        struct ScoredDocument {
            let document: DocumentItem
            let score: Float
        }

        let scored = docs.map { document in
            let vectorScore: Float
            if let vector, !vector.isEmpty, !document.vector.isEmpty {
                vectorScore = VectorMath.cosineSimilarity(vector, document.vector)
            } else {
                vectorScore = 0
            }

            let searchableText = "\(document.title)\n\(document.content)".lowercased()
            let matchingTerms = terms.reduce(into: 0) { count, term in
                if searchableText.contains(term) { count += 1 }
            }
            let keywordScore = terms.isEmpty ? Float(0) : Float(matchingTerms) / Float(terms.count)
            let hasQuery = vector != nil || !terms.isEmpty
            let score = hasQuery ? alpha * vectorScore + beta * keywordScore : 0
            return ScoredDocument(document: document, score: score)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.document.updatedAt != rhs.document.updatedAt {
                return lhs.document.updatedAt > rhs.document.updatedAt
            }
            return lhs.document.id.uuidString < rhs.document.id.uuidString
        }.prefix(limit).map(\.document)
    }

    public func saveFeedback(event: MemoryFeedbackEvent) async throws {
        let metadataData = try JSONEncoder().encode(event.metadata)
        guard metadataData.count <= Self.maximumMetadataBytes else {
            throw ArchonMemoryError.inputTooLarge(maxBytes: Self.maximumMetadataBytes)
        }
        let metadataJSON = String(data: metadataData, encoding: .utf8) ?? "{}"
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_feedback (id, insightID, kind, userId, timestamp, metadataJson)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    insightID = excluded.insightID,
                    kind = excluded.kind,
                    userId = excluded.userId,
                    timestamp = excluded.timestamp,
                    metadataJson = excluded.metadataJson
                """,
                arguments: [
                    event.id.uuidString,
                    event.insightID.uuidString,
                    event.kind.rawValue,
                    event.userId,
                    event.timestamp.timeIntervalSince1970,
                    metadataJSON
                ]
            )
        }
    }

    public func fetchFeedback(insightID: UUID?, userId: String?, limit: Int? = nil) async throws -> [MemoryFeedbackEvent] {
        if let limit, !(0...500).contains(limit) {
            throw ArchonMemoryError.invalidSearchRequest("feedback limit must be between 0 and 500")
        }
        guard limit != 0 else { return [] }
        return try await dbQueue.read { db in
            var sql = "SELECT * FROM memory_feedback WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let insightID {
                sql += " AND insightID = ?"
                args.append(insightID.uuidString)
            }
            if let userId {
                sql += " AND userId = ?"
                args.append(userId)
            }
            sql += " ORDER BY timestamp DESC, id ASC"
            if let limit { sql += " LIMIT \(limit)" }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.compactMap { row -> MemoryFeedbackEvent? in
                guard let idString: String = row["id"],
                      let id = UUID(uuidString: idString),
                      let insightString: String = row["insightID"],
                      let insightID = UUID(uuidString: insightString),
                      let kindString: String = row["kind"],
                      let kind = MemoryFeedbackKind(rawValue: kindString) else {
                    return nil
                }
                var metadata: [String: String] = [:]
                if let metadataString: String = row["metadataJson"],
                   let data = metadataString.data(using: .utf8) {
                    guard data.count <= Self.maximumMetadataBytes else {
                        throw ArchonMemoryError.inputTooLarge(maxBytes: Self.maximumMetadataBytes)
                    }
                    metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                }
                return MemoryFeedbackEvent(
                    id: id,
                    insightID: insightID,
                    kind: kind,
                    userId: row["userId"],
                    timestamp: Date(timeIntervalSince1970: row["timestamp"]),
                    metadata: metadata
                )
            }
        }
    }

    // MARK: - Recall Memory (Letta/MemGPT)

    public func logRecallMessage(message: RecallMessage) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO recall_messages (id, role, content, userId, agentId, runId, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id.uuidString,
                    message.role.rawValue,
                    message.content,
                    message.userId,
                    message.agentId,
                    message.runId,
                    message.timestamp.timeIntervalSince1970
                ]
            )
        }
    }

    public func fetchRecallMessages(userId: String?, agentId: String?, runId: String?, limit: Int? = nil) async throws -> [RecallMessage] {
        if let limit, !(0...500).contains(limit) {
            throw ArchonMemoryError.invalidSearchRequest("recall limit must be between 0 and 500")
        }
        return try await dbQueue.read { db in
            var sql = "SELECT * FROM recall_messages WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            
            if let userId = userId {
                sql += " AND userId = ?"
                args.append(userId)
            }
            if let agentId = agentId {
                sql += " AND agentId = ?"
                args.append(agentId)
            }
            if let runId = runId {
                sql += " AND runId = ?"
                args.append(runId)
            }
            
            sql += " ORDER BY timestamp ASC"
            if let limit = limit {
                sql += " LIMIT \(limit)"
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> RecallMessage? in
                guard let idStr: String = row["id"],
                      let id = UUID(uuidString: idStr),
                      let roleStr: String = row["role"],
                      let role = Message.Role(rawValue: roleStr),
                      let content: String = row["content"],
                      let tsDouble: Double = row["timestamp"]
                else { return nil }

                return RecallMessage(
                    id: id,
                    role: role,
                    content: content,
                    userId: row["userId"],
                    agentId: row["agentId"],
                    runId: row["runId"],
                    timestamp: Date(timeIntervalSince1970: tsDouble)
                )
            }
        }
    }

    // MARK: - Conversation Summaries (Zep)

    public func saveSummary(summary: ConversationSummary) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_summaries (id, userId, agentId, runId, summary, messageCount, lastMessageTimestamp, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    summary = excluded.summary,
                    messageCount = excluded.messageCount,
                    lastMessageTimestamp = excluded.lastMessageTimestamp,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    summary.id.uuidString,
                    summary.userId,
                    summary.agentId,
                    summary.runId,
                    summary.summary,
                    summary.messageCount,
                    summary.lastMessageTimestamp.timeIntervalSince1970,
                    summary.createdAt.timeIntervalSince1970,
                    summary.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    public func fetchSummary(userId: String?, agentId: String?, runId: String?) async throws -> ConversationSummary? {
        try await dbQueue.read { db in
            var sql = "SELECT * FROM conversation_summaries WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            
            if let userId = userId {
                sql += " AND userId = ?"
                args.append(userId)
            }
            if let agentId = agentId {
                sql += " AND agentId = ?"
                args.append(agentId)
            }
            if let runId = runId {
                sql += " AND runId = ?"
                args.append(runId)
            }
            sql += " ORDER BY updatedAt DESC LIMIT 1"

            guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) else {
                return nil
            }

            return ConversationSummary(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                userId: row["userId"],
                agentId: row["agentId"],
                runId: row["runId"],
                summary: row["summary"],
                messageCount: row["messageCount"],
                lastMessageTimestamp: Date(timeIntervalSince1970: row["lastMessageTimestamp"]),
                createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
            )
        }
    }

    // MARK: - History / Auditing

    public func logHistory(item: MemoryHistoryItem) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_history (id, memoryId, action, oldMemory, newMemory, timestamp, userId)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id.uuidString,
                    item.memoryId.uuidString,
                    item.action.rawValue,
                    item.oldMemory,
                    item.newMemory,
                    item.timestamp.timeIntervalSince1970,
                    item.userId
                ]
            )
        }
    }

    public func fetchHistory(memoryId: UUID?, userId: String?) async throws -> [MemoryHistoryItem] {
        try await dbQueue.read { db in
            var sql = "SELECT * FROM memory_history WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            
            if let memoryId = memoryId {
                sql += " AND memoryId = ?"
                args.append(memoryId.uuidString)
            }
            if let userId = userId {
                sql += " AND userId = ?"
                args.append(userId)
            }
            
            sql += " ORDER BY timestamp DESC"
            
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> MemoryHistoryItem? in
                guard let idStr: String = row["id"],
                      let id = UUID(uuidString: idStr),
                      let memIdStr: String = row["memoryId"],
                      let memoryId = UUID(uuidString: memIdStr),
                      let actionStr: String = row["action"],
                      let action = MemoryAction(rawValue: actionStr),
                      let timestampDouble: Double = row["timestamp"]
                else { return nil }
                
                return MemoryHistoryItem(
                    id: id,
                    memoryId: memoryId,
                    action: action,
                    oldMemory: row["oldMemory"],
                    newMemory: row["newMemory"],
                    timestamp: Date(timeIntervalSince1970: timestampDouble),
                    userId: row["userId"]
                )
            }
        }
    }

    // MARK: - CloudKit Sync Operations

    public func fetchPendingSyncItems() async throws -> [MemoryItem] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM memories WHERE syncState = 'pendingUpload'")
            return try rows.map { try Self.rowToMemoryItem($0) }
        }
    }

    public func markSynced(ids: [UUID]) async throws {
        try await dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE memories SET syncState = 'synced' WHERE id = ?",
                    arguments: [id.uuidString]
                )
            }
        }
    }

    // MARK: - Core Working Memory Blocks

    public func getCoreMemoryBlock() async throws -> [String: String] {
        try await getCoreMemoryBlock(userId: nil)
    }

    public func getCoreMemoryBlock(userId: String?) async throws -> [String: String] {
        try await dbQueue.read { db in
            let scope = userId ?? ""
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT blockKey, blockValue FROM core_memory_blocks WHERE userId = ?",
                arguments: [scope]
            )
            var dict: [String: String] = [:]
            for row in rows {
                if let k: String = row["blockKey"], let v: String = row["blockValue"] {
                    dict[k] = v
                }
            }
            return dict
        }
    }

    public func setCoreMemoryBlock(key: String, value: String) async throws {
        try await setCoreMemoryBlock(key: key, value: value, userId: nil)
    }

    public func setCoreMemoryBlock(key: String, value: String, userId: String?) async throws {
        try await dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            let scope = userId ?? ""
            try db.execute(
                sql: """
                INSERT INTO core_memory_blocks (blockKey, userId, blockValue, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(blockKey, userId) DO UPDATE SET blockValue = excluded.blockValue, updatedAt = excluded.updatedAt
                """,
                arguments: [key, scope, value, now]
            )
        }
    }

    // MARK: - Helper Methods

    private static func rowToDocumentItem(_ row: Row) throws -> DocumentItem {
        let idString: String = row["id"]
        let id = UUID(uuidString: idString) ?? UUID()

        var vector: [Float] = []
        if let vectorBlob: Data = row["vectorData"] {
            guard vectorBlob.count % MemoryLayout<Float>.size == 0 else {
                throw ArchonMemoryError.invalidConfiguration("Stored document vector has an invalid byte length.")
            }
            vector = vectorBlob.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            try validate(vector: vector, label: "stored document")
        }

        var tags: [String] = []
        if let tagsJSON: String = row["tagsJson"], let data = tagsJSON.data(using: .utf8) {
            guard data.count <= maximumMetadataBytes else {
                throw ArchonMemoryError.inputTooLarge(maxBytes: maximumMetadataBytes)
            }
            tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }

        var metadata: [String: String] = [:]
        if let metadataJSON: String = row["metadataJson"], let data = metadataJSON.data(using: .utf8) {
            guard data.count <= maximumMetadataBytes else {
                throw ArchonMemoryError.inputTooLarge(maxBytes: maximumMetadataBytes)
            }
            metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }

        return DocumentItem(
            id: id,
            title: row["title"],
            url: row["url"],
            content: row["content"],
            chunkIndex: row["chunkIndex"],
            totalChunks: row["totalChunks"],
            vector: vector,
            tags: tags,
            userId: row["userId"],
            metadata: metadata,
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
            isDeleted: row["isDeleted"]
        )
    }

    private static func rowToMemoryItem(_ row: Row) throws -> MemoryItem {
        let idStr: String = row["id"]
        let id = UUID(uuidString: idStr) ?? UUID()
        let memory: String = row["memory"]
        let hash: String = row["hash"]
        
        var vector: [Float] = []
        if let vectorBlob: Data = row["vectorData"] {
            guard vectorBlob.count % MemoryLayout<Float>.size == 0 else {
                throw ArchonMemoryError.invalidConfiguration("Stored memory vector has an invalid byte length.")
            }
            vector = vectorBlob.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            try validate(vector: vector, label: "stored memory")
        }
        
        var metadata: [String: String] = [:]
        if let jsonStr: String = row["metadataJson"], let data = jsonStr.data(using: .utf8) {
            guard data.count <= maximumMetadataBytes else {
                throw ArchonMemoryError.inputTooLarge(maxBytes: maximumMetadataBytes)
            }
            metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        
        let validFromDouble: Double = row["validFrom"]
        let validToDouble: Double? = row["validTo"]
        let supersededStr: String? = row["supersededById"]
        
        return MemoryItem(
            id: id,
            memory: memory,
            hash: hash,
            vector: vector,
            userId: row["userId"],
            agentId: row["agentId"],
            runId: row["runId"],
            metadata: metadata,
            validFrom: Date(timeIntervalSince1970: validFromDouble),
            validTo: validToDouble != nil ? Date(timeIntervalSince1970: validToDouble!) : nil,
            supersededById: supersededStr != nil ? UUID(uuidString: supersededStr!) : nil,
            accessCount: row["accessCount"],
            lastAccessedAt: Date(timeIntervalSince1970: row["lastAccessedAt"]),
            scoreWeight: Float(row["scoreWeight"] as Double),
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
            isDeleted: row["isDeleted"],
            version: Int64(row["version"] as Int)
        )
    }

    private static func appendFilterConditions(filters: MemoryFilter?, sql: inout String, args: inout [DatabaseValueConvertible]) {
        guard let filters = filters else {
            sql += " AND isDeleted = 0"
            return
        }
        
        if !filters.includeDeleted {
            sql += " AND isDeleted = 0"
        }
        if let userId = filters.userId {
            sql += " AND userId = ?"
            args.append(userId)
        }
        if let agentId = filters.agentId {
            sql += " AND agentId = ?"
            args.append(agentId)
        }
        if let runId = filters.runId {
            sql += " AND runId = ?"
            args.append(runId)
        }
        // Metadata filtering is applied after decoding the portable JSON blob
        // in fetchAll(). Keeping it out of SQL avoids requiring SQLite JSON1
        // and ensures limit/offset are applied to the filtered result set.
        if let activeAt = filters.activeAt {
            let activeDouble = activeAt.timeIntervalSince1970
            sql += " AND validFrom <= ? AND (validTo IS NULL OR validTo > ?)"
            args.append(activeDouble)
            args.append(activeDouble)
        }
    }
}
