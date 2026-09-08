import Foundation
import GRDB

public struct ConversationRecord: Codable, Sendable, Identifiable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"
    
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    
    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MessageRecord: Codable, Sendable, Identifiable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"
    
    public var id: String
    public var conversationId: String
    public var role: String
    public var content: String
    public var createdAt: Date
    
    public init(id: String = UUID().uuidString, conversationId: String, role: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct SearchSessionRecord: Codable, Sendable, Identifiable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "search_sessions"
    
    public var id: String
    public var conversationId: String?
    public var query: String
    public var createdAt: Date
    public var searchDiagnosticsJson: String?
    
    public init(id: String = UUID().uuidString, conversationId: String? = nil, query: String, createdAt: Date = Date(), searchDiagnosticsJson: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.query = query
        self.createdAt = createdAt
        self.searchDiagnosticsJson = searchDiagnosticsJson
    }
}

public struct SourceRecord: Codable, Sendable, Identifiable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sources"
    
    public var id: String
    public var sessionId: String?
    public var url: String
    public var title: String
    public var passagesJson: String
    public var retrievedAt: Date
    
    public init(id: String = UUID().uuidString, sessionId: String? = nil, url: String, title: String, passagesJson: String = "[]", retrievedAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.url = url
        self.title = title
        self.passagesJson = passagesJson
        self.retrievedAt = retrievedAt
    }
}

public struct CitationRecord: Codable, Sendable, Identifiable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "citations"
    
    public var id: String
    public var sourceId: String
    public var passageId: String?
    public var label: String
    public var url: String
    public var title: String?
    public var snippet: String?
    
    public init(id: String = UUID().uuidString, sourceId: String, passageId: String? = nil, label: String, url: String, title: String? = nil, snippet: String? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.passageId = passageId
        self.label = label
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

public struct CacheEntryRecord: Codable, Sendable, TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cache_entries"
    
    public var url: String
    public var title: String
    public var text: String
    public var markdown: String
    public var metadataJson: String
    public var cachedAt: Date
    public var expiresAt: Date
    
    public init(url: String, title: String, text: String, markdown: String = "", metadataJson: String = "{}", cachedAt: Date = Date(), expiresAt: Date) {
        self.url = url
        self.title = title
        self.text = text
        self.markdown = markdown
        self.metadataJson = metadataJson
        self.cachedAt = cachedAt
        self.expiresAt = expiresAt
    }
}
