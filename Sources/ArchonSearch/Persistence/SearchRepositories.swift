import Foundation
import GRDB

public protocol ConversationRepository: Sendable {
    func saveConversation(id: String, title: String) async throws
    func fetchConversation(id: String) async throws -> ConversationRecord?
    func saveMessage(id: String, conversationId: String, role: String, content: String) async throws
    func fetchMessages(conversationId: String) async throws -> [MessageRecord]
}

public protocol SourceRepository: Sendable {
    func saveSource(_ source: Source, sessionId: String?) async throws
    func fetchSources(sessionId: String) async throws -> [Source]
    func saveCitation(_ citation: Citation) async throws
    func fetchCitations(sourceId: UUID) async throws -> [Citation]
}

public protocol WebPageCacheRepository: Sendable {
    func getCachedDocument(url: URL) async throws -> WebDocument?
    func setCachedDocument(_ document: WebDocument, ttl: TimeInterval) async throws
    func evictExpired() async throws
}

public actor GRDBConversationRepository: ConversationRepository {
    private let database: SearchDatabase
    public init(database: SearchDatabase) { self.database = database }
    
    public func saveConversation(id: String, title: String) async throws {
        try await database.write { db in
            var record = ConversationRecord(id: id, title: title)
            try record.save(db)
        }
    }
    
    public func fetchConversation(id: String) async throws -> ConversationRecord? {
        try await database.read { db in try ConversationRecord.fetchOne(db, key: id) }
    }
    
    public func saveMessage(id: String, conversationId: String, role: String, content: String) async throws {
        try await database.write { db in
            var record = MessageRecord(id: id, conversationId: conversationId, role: role, content: content)
            try record.save(db)
        }
    }
    
    public func fetchMessages(conversationId: String) async throws -> [MessageRecord] {
        try await database.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }
}

public actor GRDBSourceRepository: SourceRepository {
    private let database: SearchDatabase
    public init(database: SearchDatabase) { self.database = database }
    
    public func saveSource(_ source: Source, sessionId: String?) async throws {
        let passagesData = try JSONEncoder().encode(source.passages)
        let passagesJson = String(decoding: passagesData, as: UTF8.self)
        try await database.write { db in
            var record = SourceRecord(id: source.id.uuidString, sessionId: sessionId, url: source.url.absoluteString, title: source.title, passagesJson: passagesJson, retrievedAt: source.retrievedAt)
            try record.save(db)
        }
    }
    
    public func fetchSources(sessionId: String) async throws -> [Source] {
        try await database.read { db in
            let records = try SourceRecord.filter(Column("sessionId") == sessionId).fetchAll(db)
            return records.compactMap { r in
                guard let url = URL(string: r.url), let id = UUID(uuidString: r.id) else { return nil }
                let passages = (try? JSONDecoder().decode([SourcePassage].self, from: Data(r.passagesJson.utf8))) ?? []
                return Source(id: id, url: url, title: r.title, passages: passages, retrievedAt: r.retrievedAt)
            }
        }
    }
    
    public func saveCitation(_ citation: Citation) async throws {
        try await database.write { db in
            var record = CitationRecord(id: citation.id.uuidString, sourceId: citation.sourceID.uuidString, passageId: citation.passageID?.uuidString, label: citation.label, url: citation.url.absoluteString, title: citation.title, snippet: citation.snippet)
            try record.save(db)
        }
    }
    
    public func fetchCitations(sourceId: UUID) async throws -> [Citation] {
        try await database.read { db in
            let records = try CitationRecord.filter(Column("sourceId") == sourceId.uuidString).fetchAll(db)
            return records.compactMap { r in
                guard let url = URL(string: r.url), let id = UUID(uuidString: r.id), let srcId = UUID(uuidString: r.sourceId) else { return nil }
                let passId = r.passageId.flatMap(UUID.init(uuidString:))
                return Citation(id: id, label: r.label, sourceID: srcId, passageID: passId, url: url, title: r.title, snippet: r.snippet)
            }
        }
    }
}

public actor GRDBCacheRepository: WebPageCacheRepository {
    private let database: SearchDatabase
    public init(database: SearchDatabase) { self.database = database }
    
    public func getCachedDocument(url: URL) async throws -> WebDocument? {
        try await database.read { db in
            guard let record = try CacheEntryRecord.fetchOne(db, key: url.absoluteString),
                  record.expiresAt > Date() else { return nil }
            let metadata = (try? JSONDecoder().decode([String: String].self, from: Data(record.metadataJson.utf8))) ?? [:]
            return WebDocument(url: url, title: record.title, text: record.text, markdown: record.markdown, publishedAt: nil, metadata: metadata)
        }
    }
    
    public func setCachedDocument(_ document: WebDocument, ttl: TimeInterval) async throws {
        let metaData = try JSONEncoder().encode(document.metadata)
        let metaJson = String(decoding: metaData, as: UTF8.self)
        let expiresAt = Date().addingTimeInterval(ttl)
        try await database.write { db in
            var record = CacheEntryRecord(url: document.url.absoluteString, title: document.title, text: document.text, markdown: document.markdown, metadataJson: metaJson, expiresAt: expiresAt)
            try record.save(db)
        }
    }
    
    public func evictExpired() async throws {
        try await database.write { db in
            _ = try CacheEntryRecord.filter(Column("expiresAt") <= Date()).deleteAll(db)
        }
    }
}
