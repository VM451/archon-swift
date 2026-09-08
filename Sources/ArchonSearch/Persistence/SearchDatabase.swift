import Foundation
import GRDB

/// Actor managing the local SQLite database for search sessions, conversations, and cache.
public actor SearchDatabase: Sendable {
    public let dbWriter: any DatabaseWriter
    
    public init(databasePath: String? = nil, inMemory: Bool = false) throws {
        if inMemory {
            let queue = try DatabaseQueue()
            try Self.setupSchema(queue)
            self.dbWriter = queue
        } else {
            let path: String
            if let databasePath {
                path = databasePath
            } else {
                let fm = FileManager.default
                let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                let appSupport = urls.first ?? fm.temporaryDirectory
                let searchDir = appSupport.appendingPathComponent("ArchonSearch", isDirectory: true)
                try fm.createDirectory(at: searchDir, withIntermediateDirectories: true)
                path = searchDir.appendingPathComponent("search_store.sqlite").path
            }
            let queue = try DatabaseQueue(path: path)
            try Self.setupSchema(queue)
            self.dbWriter = queue
        }
    }
    
    public init(dbWriter: any DatabaseWriter) throws {
        try Self.setupSchema(dbWriter)
        self.dbWriter = dbWriter
    }
    
    public static func setupSchema(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1_create_search_tables") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().indexed()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "search_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).indexed()
                t.column("query", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("searchDiagnosticsJson", .text)
            }
            try db.create(table: "sources") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).indexed()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("passagesJson", .text).notNull()
                t.column("retrievedAt", .datetime).notNull()
            }
            try db.create(table: "citations") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceId", .text).notNull().indexed()
                t.column("passageId", .text)
                t.column("label", .text).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("snippet", .text)
            }
            try db.create(table: "cache_entries") { t in
                t.column("url", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("text", .text).notNull()
                t.column("markdown", .text).notNull()
                t.column("metadataJson", .text).notNull()
                t.column("cachedAt", .datetime).notNull()
                t.column("expiresAt", .datetime).notNull().indexed()
            }
        }
        
        try migrator.migrate(writer)
    }
    
    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }
    
    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }
}
