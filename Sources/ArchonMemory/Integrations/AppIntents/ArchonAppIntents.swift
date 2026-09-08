import Foundation
import AppIntents

/// AppIntent allowing Siri & Apple Shortcuts to search user memories.
public struct SearchMemoriesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search AI Memories"
    public static let description = IntentDescription("Searches stored AI user memories using vector similarity and keywords.")

    @Parameter(title: "Query", description: "Search query string")
    public var query: String

    @Parameter(title: "User ID", description: "Optional User Identifier filter")
    public var userId: String?

    @Parameter(title: "Workspace ID", description: "Optional ArchonMemory workspace namespace")
    public var workspaceID: String?

    public init() {
        self.query = ""
        self.userId = nil
        self.workspaceID = nil
    }

    public init(query: String, userId: String? = nil, workspaceID: String? = nil) {
        self.query = query
        self.userId = userId
        self.workspaceID = workspaceID
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard let client = await ArchonClientIntentRegistry.shared.current(for: workspaceID ?? "default") else {
            throw ArchonMemoryError.invalidConfiguration("ArchonClient shared instance is not initialized.")
        }
        
        let results = try await client.search(query: query, userId: userId, limit: 5)
        let memoryTexts = results.map { "\($0.item.memory) (Score: \(String(format: "%.2f", $0.score)))" }
        return .result(value: memoryTexts)
    }
}

/// AppIntent allowing Siri & Apple Shortcuts to manually save a new memory.
public struct AddMemoryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add AI Memory"
    public static let description = IntentDescription("Stores a new factual memory item into ArchonMemory.")

    @Parameter(title: "Memory Text", description: "Text content of the memory")
    public var memoryText: String

    @Parameter(title: "User ID", description: "Optional User Identifier")
    public var userId: String?

    @Parameter(title: "Workspace ID", description: "Optional ArchonMemory workspace namespace")
    public var workspaceID: String?

    public init() {
        self.memoryText = ""
        self.userId = nil
        self.workspaceID = nil
    }

    public init(memoryText: String, userId: String? = nil, workspaceID: String? = nil) {
        self.memoryText = memoryText
        self.userId = userId
        self.workspaceID = workspaceID
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let client = await ArchonClientIntentRegistry.shared.current(for: workspaceID ?? "default") else {
            throw ArchonMemoryError.invalidConfiguration("ArchonClient shared instance is not initialized.")
        }
        
        let message = Message(role: .user, content: memoryText)
        let changeset = try await client.add(messages: [message], userId: userId)
        return .result(value: "Added \(changeset.affectedItems.count) memory item(s).")
    }
}
