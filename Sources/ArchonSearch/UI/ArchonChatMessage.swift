import Foundation

/// Represents a single message in the ArchonChat UI.
public struct ArchonChatMessage: Identifiable, Sendable, Hashable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String
    public let citations: [Citation]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        citations: [Citation] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.timestamp = timestamp
    }
}
