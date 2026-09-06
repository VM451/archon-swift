import Foundation
import OSLog

/// Actor-backed host registration for memory App Intents and background work.
///
/// Apps register their configured client during startup. Consumers that do not
/// use App Intents or background maintenance can leave the registry empty.
public actor ArchonClientIntentRegistry {
    public static let shared = ArchonClientIntentRegistry()

    private var client: ArchonClient?

    public init() {}

    public func register(_ client: ArchonClient) {
        self.client = client
    }

    public func unregister() {
        client = nil
    }

    public func current() -> ArchonClient? {
        client
    }
}

/// Primary entry point for ArchonMemory library. Manages local vector storage, Knowledge Graph extraction,
/// Supermemory document ingestion, Letta hierarchical recall memory, Zep dialogue summaries,
/// Spotlight search indexing, working memory blocks, and CloudKit background sync.
public actor ArchonClient: CoreMemoryManager, MemoryAgentTool {
    public let config: ArchonConfig
    public let vectorStore: VectorStore
    public let graphStore: GraphStore
    public let extractor: MemoryExtractor
    public let summarizer: DialogueSummarizer
    public let chunker: ContentChunker
    public let syncEngine: CloudKitSyncEngine?
    public let spotlightIndexer: CoreSpotlightIndexer
    public let knowledgeBaseIndex: KnowledgeBaseIndex
    public let ragRetriever: RAGRetriever

    private let logger = Logger(subsystem: "com.archon.memory.swift", category: "ArchonClient")
    private var scheduledSyncTask: Task<Void, Never>?
    private var syncInProgress = false

    public init(config: ArchonConfig = ArchonConfig()) async throws {
        self.config = config
        
        if let store = config.customVectorStore {
            self.vectorStore = store
        } else {
            self.vectorStore = try LocalVectorStore(databasePath: config.databasePath)
        }
        
        if let gStore = config.customGraphStore {
            self.graphStore = gStore
        } else {
            self.graphStore = try LocalGraphStore(databasePath: Self.graphDatabasePath(for: config.databasePath))
        }
        
        self.extractor = MemoryExtractor(
            vectorStore: vectorStore,
            graphStore: graphStore,
            embeddingProvider: config.embeddingProvider,
            llmProvider: config.llmProvider,
            customExtractionPrompt: config.customExtractionPrompt,
            policy: config.extractionPolicy
        )

        self.summarizer = DialogueSummarizer(llmProvider: config.llmProvider)
        self.chunker = ContentChunker()
        let kbIndex = KnowledgeBaseIndex(embeddingProvider: config.embeddingProvider)
        self.knowledgeBaseIndex = kbIndex
        self.ragRetriever = RAGRetriever(index: kbIndex)

        if config.enableAutoSync {
            guard let containerId = config.cloudKitContainerId,
                  !containerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchonMemoryError.invalidConfiguration("enableAutoSync requires cloudKitContainerId.")
            }
            let engine = CloudKitSyncEngine(containerId: containerId, changeTokenURL: config.cloudKitChangeTokenPath.map(URL.init(fileURLWithPath:)))
            self.syncEngine = engine
            try await engine.setupZoneAndSubscriptions()
        } else {
            self.syncEngine = nil
        }
        
        self.spotlightIndexer = CoreSpotlightIndexer.shared
        
        await ArchonClientIntentRegistry.shared.register(self)
    }

    private static func graphDatabasePath(for databasePath: String?) -> String? {
        guard let databasePath else { return nil }
        let url = URL(fileURLWithPath: databasePath)
        let baseName = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(baseName + "-graph.sqlite")
            .path
    }

    // MARK: - Public Client Core APIs

    /// Extracts and adds/updates memories and knowledge graph relations from conversation turns.
    @discardableResult
    public func add(
        messages: [Message],
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> MemoryChangeset {
        // Log into chronological recall memory (Letta)
        for msg in messages {
            try? await vectorStore.logRecallMessage(message: RecallMessage(
                role: msg.role,
                content: msg.content,
                userId: userId,
                agentId: agentId,
                runId: runId
            ))
        }

        let changeset = try await extractor.extractAndApply(
            messages: messages,
            userId: userId,
            agentId: agentId,
            runId: runId,
            metadata: metadata
        )

        let affected = changeset.affectedItems
        if config.enableSpotlightIndexing, !affected.isEmpty {
            let indexer = spotlightIndexer
            Task {
                try? await indexer.index(memories: affected)
            }
        }

        if config.enableAutoSync, !affected.isEmpty {
            scheduleSync()
        }

        return changeset
    }

    /// Directly saves a single textual memory statement.
    @discardableResult
    public func add(
        memory: String,
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> MemoryItem {
        let vector = try await config.embeddingProvider.embed(text: memory)
        let item = MemoryItem(
            memory: memory,
            vector: vector,
            userId: userId,
            agentId: agentId,
            runId: runId,
            metadata: metadata
        )

        try await vectorStore.save(item: item)
        try await vectorStore.logHistory(item: MemoryHistoryItem(
            memoryId: item.id,
            action: .add,
            newMemory: item.memory,
            userId: userId
        ))

        let items = [item]
        if config.enableSpotlightIndexing {
            let indexer = spotlightIndexer
            Task {
                try? await indexer.index(memories: items)
            }
        }

        if config.enableAutoSync {
            scheduleSync()
        }

        return item
    }

    /// Directly saves multiple raw memory statements in batch.
    @discardableResult
    public func batchAdd(
        memories: [String],
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> [MemoryItem] {
        var items: [MemoryItem] = []
        for text in memories {
            let vector = try await config.embeddingProvider.embed(text: text)
            let item = MemoryItem(
                memory: text,
                vector: vector,
                userId: userId,
                agentId: agentId,
                runId: runId,
                metadata: metadata
            )
            items.append(item)
        }

        try await vectorStore.saveBatch(items: items)
        for item in items {
            try await vectorStore.logHistory(item: MemoryHistoryItem(
                memoryId: item.id,
                action: .add,
                newMemory: item.memory,
                userId: userId
            ))
        }
        
        let batchItems = items
        if config.enableSpotlightIndexing, !batchItems.isEmpty {
            let indexer = spotlightIndexer
            Task {
                try? await indexer.index(memories: batchItems)
            }
        }

        if config.enableAutoSync, !batchItems.isEmpty {
            scheduleSync()
        }

        return items
    }

    /// Searches relevant memories using vector similarity and BM25 text rank fusion.
    public func search(
        query: String,
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        limit: Int = 5
    ) async throws -> [SearchResult] {
        let vector = try await config.embeddingProvider.embed(text: query)
        let filter = MemoryFilter(
            userId: userId,
            agentId: agentId,
            runId: runId,
            includeDeleted: config.retrievalPolicy.includeDeleted
        )
        let boundedLimit = min(max(limit, 0), config.retrievalPolicy.maximumResults)
        return try await vectorStore.search(query: query, vector: vector, limit: boundedLimit, filters: filter)
    }

    /// Fetch a memory by its UUID.
    public func get(id: UUID) async throws -> MemoryItem? {
        return try await vectorStore.fetch(id: id)
    }

    /// Fetch all memories matching optional filters, with optional pagination.
    public func getAll(
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> [MemoryItem] {
        let filter = MemoryFilter(
            userId: userId,
            agentId: agentId,
            runId: runId,
            includeDeleted: config.retrievalPolicy.includeDeleted
        )
        let requestedLimit = limit ?? config.retrievalPolicy.maximumResults
        let boundedLimit = min(max(requestedLimit, 0), config.retrievalPolicy.maximumResults)
        return try await vectorStore.fetchAll(filters: filter, limit: boundedLimit, offset: offset)
    }

    /// Update an existing memory item.
    @discardableResult
    public func update(id: UUID, memory: String) async throws -> MemoryItem {
        guard var existing = try await vectorStore.fetch(id: id) else {
            throw ArchonMemoryError.memoryNotFound(id)
        }

        let oldText = existing.memory
        let newVector = try await config.embeddingProvider.embed(text: memory)

        existing.memory = memory
        existing.hash = MemoryItem.computeHash(for: memory)
        existing.vector = newVector
        existing.updatedAt = Date()
        existing.version += 1

        try await vectorStore.save(item: existing)
        try await vectorStore.logHistory(item: MemoryHistoryItem(
            memoryId: existing.id,
            action: .update,
            oldMemory: oldText,
            newMemory: memory,
            userId: existing.userId
        ))

        let updatedItems = [existing]
        if config.enableSpotlightIndexing {
            let indexer = spotlightIndexer
            Task {
                try? await indexer.index(memories: updatedItems)
            }
        }

        if config.enableAutoSync {
            scheduleSync()
        }

        return existing
    }

    /// Delete a single memory item.
    public func delete(id: UUID) async throws {
        guard let existing = try await vectorStore.fetch(id: id) else { return }
        
        try await vectorStore.delete(id: id)
        try await vectorStore.logHistory(item: MemoryHistoryItem(
            memoryId: id,
            action: .delete,
            oldMemory: existing.memory,
            userId: existing.userId
        ))

        let deleteId = id
        if config.enableSpotlightIndexing {
            let indexer = spotlightIndexer
            Task {
                try? await indexer.deindex(ids: [deleteId])
            }
        }
        if config.enableAutoSync {
            scheduleSync()
        }
    }

    /// Bulk delete all memories matching a specific user, agent, or run session.
    public func deleteAll(userId: String? = nil, agentId: String? = nil, runId: String? = nil) async throws {
        try await deleteAll(userId: userId, agentId: agentId, runId: runId, schedule: true)
    }

    private func deleteAll(
        userId: String?,
        agentId: String?,
        runId: String?,
        schedule: Bool
    ) async throws {
        let existing = try await vectorStore.fetchAll(
            filters: MemoryFilter(userId: userId, agentId: agentId, runId: runId),
            limit: nil,
            offset: nil
        )
        try await vectorStore.deleteAll(userId: userId, agentId: agentId, runId: runId)
        try await graphStore.deleteAll(userId: userId, agentId: agentId, runId: runId)
        for item in existing {
            try await vectorStore.logHistory(item: MemoryHistoryItem(
                memoryId: item.id,
                action: .delete,
                oldMemory: item.memory,
                userId: item.userId
            ))
        }
        if config.enableSpotlightIndexing, !existing.isEmpty {
            try? await spotlightIndexer.deindex(ids: existing.map(\.id))
        }
        if config.enableAutoSync, schedule {
            scheduleSync()
        }
    }

    /// Completely wipe all stored memories, history logs, documents, and working blocks.
    public func reset() async throws {
        if config.enableAutoSync {
            try await deleteAll(userId: nil, agentId: nil, runId: nil, schedule: false)
            try await sync()
        } else if config.enableSpotlightIndexing {
            try? await spotlightIndexer.deindexAll()
        }
        try await vectorStore.reset()
        try await graphStore.deleteAll(userId: nil, agentId: nil, runId: nil)
    }

    /// Retrieve audit history logs.
    public func history(memoryId: UUID? = nil, userId: String? = nil) async throws -> [MemoryHistoryItem] {
        return try await vectorStore.fetchHistory(memoryId: memoryId, userId: userId)
    }

    /// Permanently forgets a memory from local indexes while retaining a
    /// tombstone long enough for an enabled CloudKit sync to propagate it.
    public func forget(id: UUID) async throws {
        try await delete(id: id)
    }

    /// Exports durable local memory state as portable JSON for backup or
    /// account migration. Deleted memory tombstones are included explicitly.
    public func export(
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil
    ) async throws -> Data {
        let memories = try await vectorStore.fetchAll(
            filters: MemoryFilter(userId: userId, agentId: agentId, runId: runId, includeDeleted: true),
            limit: nil,
            offset: nil
        )
        let history = try await vectorStore.fetchHistory(memoryId: nil, userId: userId)
        let entities = try await graphStore.fetchEntities(userId: userId)
        let relations = try await graphStore.fetchTriples(userId: userId)
        return try JSONEncoder().encode(ArchonMemoryExport(
            memories: memories,
            history: history,
            entities: entities,
            relations: relations
        ))
    }

    // MARK: - Supermemory Document & Bookmark Ingestion

    /// Ingests a long document, bookmark, or article with automatic chunking, tagging, and vector indexing.
    @discardableResult
    public func ingest(
        content: String,
        title: String,
        url: String? = nil,
        userId: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) async throws -> [DocumentItem] {
        guard content.utf8.count <= PlainTextDocumentLoader.maxInputBytes else {
            throw ArchonMemoryError.inputTooLarge(maxBytes: PlainTextDocumentLoader.maxInputBytes)
        }
        let chunks = chunker.chunk(text: content)
        let autoTags = tags.isEmpty ? chunker.extractTags(text: content) : tags
        
        var documents: [DocumentItem] = []
        for (index, chunkText) in chunks.enumerated() {
            let vector = try await config.embeddingProvider.embed(text: "\(title)\n\(chunkText)")
            let doc = DocumentItem(
                title: title,
                url: url,
                content: chunkText,
                chunkIndex: index,
                totalChunks: chunks.count,
                vector: vector,
                tags: autoTags,
                userId: userId,
                metadata: metadata
            )
            try await vectorStore.saveDocument(doc: doc)
            documents.append(doc)
        }

        return documents
    }

    /// Search ingested documents and bookmarks by query.
    public func searchDocuments(
        query: String,
        userId: String? = nil,
        limit: Int = 5
    ) async throws -> [DocumentItem] {
        let vector = try await config.embeddingProvider.embed(text: query)
        return try await vectorStore.searchDocuments(query: query, vector: vector, limit: limit, userId: userId)
    }

    /// Ingests a local file (PDF, Markdown, Code, PlainText, CSV/JSON, Notes export) into the Knowledge Base Index.
    @discardableResult
    public func ingestDocument(
        fileURL: URL,
        loader: (any DocumentLoader)? = nil,
        tags: [String] = [],
        userId: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> [DocumentChunk] {
        try DocumentInputLimits.validate(fileURL: fileURL)
        let docLoader = loader ?? AutoDocumentLoader()
        let loadedDocs = try await docLoader.load(from: fileURL)
        var allChunks: [DocumentChunk] = []

        for loaded in loadedDocs {
            let chunks = try await knowledgeBaseIndex.index(document: loaded, tags: tags, userId: userId)
            allChunks.append(contentsOf: chunks)

            // Also mirror to persistent vectorStore for backwards compatibility
            for (idx, chunk) in chunks.enumerated() {
                let vector = try await config.embeddingProvider.embed(text: "\(loaded.title)\n\(chunk.text)")
                let doc = DocumentItem(
                    title: loaded.title,
                    url: fileURL.absoluteString,
                    content: chunk.text,
                    chunkIndex: idx,
                    totalChunks: chunks.count,
                    vector: vector,
                    tags: tags,
                    userId: userId,
                    metadata: metadata
                )
                try await vectorStore.saveDocument(doc: doc)
            }
        }

        return allChunks
    }

    /// Ingests raw document data into the Knowledge Base Index.
    @discardableResult
    public func ingestDocumentData(
        data: Data,
        filename: String,
        loader: (any DocumentLoader)? = nil,
        tags: [String] = [],
        userId: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> [DocumentChunk] {
        guard data.count <= PlainTextDocumentLoader.maxInputBytes else {
            throw ArchonMemoryError.inputTooLarge(maxBytes: PlainTextDocumentLoader.maxInputBytes)
        }
        let docLoader = loader ?? AutoDocumentLoader()
        let loadedDocs = try await docLoader.load(data: data, filename: filename, metadata: metadata)
        var allChunks: [DocumentChunk] = []

        for loaded in loadedDocs {
            let chunks = try await knowledgeBaseIndex.index(document: loaded, tags: tags, userId: userId)
            allChunks.append(contentsOf: chunks)
        }

        return allChunks
    }

    /// Retrieves an LLM-ready RAG context with numbered citations ([1], [2]) from indexed personal documents.
    public func retrieveContext(
        query: String,
        limit: Int = 5,
        filter: DocumentFilter? = nil
    ) async throws -> RAGContext {
        return try await ragRetriever.retrieveContext(query: query, limit: limit, filter: filter)
    }

    /// Queries the personal knowledge base index directly.
    public func searchKnowledgeBase(
        query: String,
        limit: Int = 5,
        filter: DocumentFilter? = nil
    ) async throws -> [RetrievalResult] {
        return try await knowledgeBaseIndex.retrieve(query: query, limit: limit, filter: filter)
    }

    // MARK: - Letta/MemGPT Hierarchical Recall Memory

    /// Retrieves chronological conversation turns for message playback and short-term dialogue recall.
    public func recall(
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil,
        limit: Int? = 50
    ) async throws -> [RecallMessage] {
        return try await vectorStore.fetchRecallMessages(userId: userId, agentId: agentId, runId: runId, limit: limit)
    }

    // MARK: - Zep Dialogue Summarization

    /// Generates and stores a progressive rolling dialogue summary for a user conversation.
    @discardableResult
    public func summarize(
        messages: [Message],
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil
    ) async throws -> ConversationSummary {
        let existingSummary = try await vectorStore.fetchSummary(userId: userId, agentId: agentId, runId: runId)
        let newSummaryText = try await summarizer.summarize(messages: messages, priorSummary: existingSummary?.summary)
        
        let summaryObj = ConversationSummary(
            id: existingSummary?.id ?? UUID(),
            userId: userId,
            agentId: agentId,
            runId: runId,
            summary: newSummaryText,
            messageCount: (existingSummary?.messageCount ?? 0) + messages.count,
            lastMessageTimestamp: Date()
        )

        try await vectorStore.saveSummary(summary: summaryObj)
        return summaryObj
    }

    /// Fetches the latest rolling dialogue summary for a user.
    public func getConversationSummary(
        userId: String? = nil,
        agentId: String? = nil,
        runId: String? = nil
    ) async throws -> ConversationSummary? {
        return try await vectorStore.fetchSummary(userId: userId, agentId: agentId, runId: runId)
    }

    // MARK: - Knowledge Graph APIs

    /// Retrieve all knowledge graph entities for a user.
    public func getEntities(userId: String? = nil) async throws -> [Entity] {
        return try await graphStore.fetchEntities(userId: userId)
    }

    /// Retrieve all knowledge graph relational triples for a user.
    public func getRelations(userId: String? = nil) async throws -> [GraphTriple] {
        return try await graphStore.fetchTriples(userId: userId)
    }

    /// Trigger bi-directional CloudKit delta sync pass manually.
    public func sync() async throws {
        guard let syncEngine = syncEngine else { return }
        guard !syncInProgress else { throw ArchonCloudKitError.syncInProgress }
        syncInProgress = true
        defer { syncInProgress = false }

        let pendingUploads = try await vectorStore.fetchPendingSyncItems()
        if !pendingUploads.isEmpty {
            try await syncEngine.upload(memories: pendingUploads)
            try await vectorStore.markSynced(ids: pendingUploads.map { $0.id })
        }

        let (pendingEntities, pendingRelations) = try await graphStore.fetchPendingSyncGraph()
        if !pendingEntities.isEmpty || !pendingRelations.isEmpty {
            try await syncEngine.uploadGraph(entities: pendingEntities, relations: pendingRelations)
            try await graphStore.markGraphSynced(
                entityIds: pendingEntities.map { $0.id },
                relationIds: pendingRelations.map { $0.id }
            )
        }

        let changes = try await syncEngine.fetchChanges()
        try await applyRemoteChanges(changes, using: syncEngine)
        try await syncEngine.commitChangeToken(changes.newChangeToken)
    }

    private func scheduleSync() {
        guard syncEngine != nil, scheduledSyncTask == nil else { return }
        scheduledSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sync()
            } catch {
                await self.recordAutomaticSyncFailure(error)
            }
            await self.finishScheduledSync()
        }
    }

    private func recordAutomaticSyncFailure(_ error: Error) {
        logger.error("Automatic CloudKit sync failed: \(error.localizedDescription, privacy: .public)")
    }

    private func finishScheduledSync() {
        scheduledSyncTask = nil
    }

    private func applyRemoteChanges(
        _ changes: CloudKitSyncEngine.SyncFetchResult,
        using syncEngine: CloudKitSyncEngine
    ) async throws {
        var syncedMemoryIDs: [UUID] = []
        for remote in changes.updatedMemories {
            if let local = try await vectorStore.fetch(id: remote.id) {
                let winner = syncEngine.resolveConflicts(local: local, remote: remote)
                if winner != local {
                    try await vectorStore.save(item: winner)
                    syncedMemoryIDs.append(winner.id)
                }
            } else {
                try await vectorStore.save(item: remote)
                syncedMemoryIDs.append(remote.id)
            }
        }
        if !syncedMemoryIDs.isEmpty {
            try await vectorStore.markSynced(ids: syncedMemoryIDs)
        }

        var syncedEntityIDs: [UUID] = []
        var syncedRelationIDs: [UUID] = []
        for remote in changes.updatedEntities {
            if let local = try await graphStore.fetchEntity(id: remote.id) {
                let winner = syncEngine.resolveEntityConflicts(local: local, remote: remote)
                if winner != local {
                    try await graphStore.saveEntity(winner)
                    syncedEntityIDs.append(winner.id)
                }
            } else {
                try await graphStore.saveEntity(remote)
                syncedEntityIDs.append(remote.id)
            }
        }
        for remote in changes.updatedRelations {
            if let local = try await graphStore.fetchRelation(id: remote.id) {
                let winner = syncEngine.resolveRelationConflicts(local: local, remote: remote)
                if winner != local {
                    try await graphStore.saveRelation(winner)
                    syncedRelationIDs.append(winner.id)
                }
            } else {
                try await graphStore.saveRelation(remote)
                syncedRelationIDs.append(remote.id)
            }
        }
        if !syncedEntityIDs.isEmpty || !syncedRelationIDs.isEmpty {
            try await graphStore.markGraphSynced(entityIds: syncedEntityIDs, relationIds: syncedRelationIDs)
        }

        var deletedMemoryIDs: [UUID] = []
        var deletedEntityIDs: [UUID] = []
        var deletedRelationIDs: [UUID] = []
        for deleted in changes.deletedRecords {
            switch deleted.recordType {
            case "ArchonMemory":
                if try await vectorStore.fetch(id: deleted.id) != nil {
                    try await vectorStore.delete(id: deleted.id)
                    deletedMemoryIDs.append(deleted.id)
                }
            case "ArchonEntity":
                if try await graphStore.fetchEntity(id: deleted.id) != nil {
                    try await graphStore.deleteEntity(id: deleted.id)
                    deletedEntityIDs.append(deleted.id)
                }
            case "ArchonRelation":
                if try await graphStore.fetchRelation(id: deleted.id) != nil {
                    try await graphStore.deleteRelation(id: deleted.id)
                    deletedRelationIDs.append(deleted.id)
                }
            default:
                continue
            }
        }
        if !deletedMemoryIDs.isEmpty {
            try await vectorStore.markSynced(ids: deletedMemoryIDs)
        }
        if !deletedEntityIDs.isEmpty || !deletedRelationIDs.isEmpty {
            try await graphStore.markGraphSynced(entityIds: deletedEntityIDs, relationIds: deletedRelationIDs)
        }
    }


    // MARK: - CoreMemoryManager & MemoryAgentTool Protocol Compliance

    public var coreBlock: [String: String] {
        get async throws {
            if let localStore = vectorStore as? LocalVectorStore {
                return try await localStore.getCoreMemoryBlock()
            }
            return [:]
        }
    }

    public func updateCoreBlock(key: String, value: String) async throws {
        try await updateCoreBlock(key: key, value: value, userId: nil)
    }

    public func coreBlock(userId: String?) async throws -> [String: String] {
        if let localStore = vectorStore as? LocalVectorStore {
            return try await localStore.getCoreMemoryBlock(userId: userId)
        }
        return [:]
    }

    public func updateCoreBlock(key: String, value: String, userId: String?) async throws {
        if let localStore = vectorStore as? LocalVectorStore {
            try await localStore.setCoreMemoryBlock(key: key, value: value, userId: userId)
        }
    }

    public func searchMemory(query: String) async throws -> String {
        let results = try await search(query: query, limit: 5)
        return results.map { "- \($0.item.memory)" }.joined(separator: "\n")
    }
}
