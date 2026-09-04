import Foundation

/// Built-in tool for hybrid vector and keyword search across long-term agent memory.
public struct MemorySearchTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "memorySearch",
            description: "Performs hybrid semantic and keyword search across persistent agent memory and user facts.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Natural language query or keywords to search in memory")
                    ]),
                    "userId": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional user or agent ID scope for memory filtering")
                    ]),
                    "limit": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Maximum number of relevant memory items to return (default: 5)")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    }

    private let searchHandler: @Sendable (String, String?, Int) async throws -> String

    public init(searchHandler: @escaping @Sendable (_ query: String, _ userId: String?, _ limit: Int) async throws -> String) {
        self.searchHandler = searchHandler
    }

    /// Creates a deterministic test double. Production callers should inject
    /// a handler backed by ArchonMemory's persistent store.
    public init(mockMemories: [String]) {
        self.searchHandler = { query, _, limit in
            let matching = mockMemories.filter { $0.localizedCaseInsensitiveContains(query) }
            let results = matching.isEmpty ? mockMemories : matching
            let limited = Array(results.prefix(limit))
            return limited.isEmpty ? "No relevant memories found for query: '\(query)'." : limited.joined(separator: "\n- ")
        }
    }

    public init() {
        self.searchHandler = { _, _, _ in
            throw GraphError.toolExecutionFailed(
                toolName: "memorySearch",
                errorDescription: "No persistent memory search provider has been configured."
            )
        }
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "memorySearch", errorDescription: "Missing or invalid 'query' parameter.")
        }

        let userId = json["userId"] as? String
        let requestedLimit = (json["limit"] as? Int) ?? 5
        guard (0...100).contains(requestedLimit) else {
            throw GraphError.toolExecutionFailed(toolName: "memorySearch", errorDescription: "limit must be between 0 and 100.")
        }
        let limit = requestedLimit
        return try await searchHandler(query, userId, limit)
    }
}

/// Built-in tool for saving facts, conversational turns, or entity triples into persistent agent memory.
public struct MemoryStoreTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "memoryStore",
            description: "Stores a verified fact, knowledge triple, or user preference into persistent long-term memory.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "fact": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The factual memory statement or preference to persist")
                    ]),
                    "userId": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("User or session ID associated with this memory")
                    ]),
                    "category": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional category tag (e.g., 'preference', 'entity', 'rule')")
                    ])
                ]),
                "required": AnySendable([AnySendable("fact")])
            ]
        )
    }

    private let storeHandler: @Sendable (String, String?, String?) async throws -> String

    public init(storeHandler: @escaping @Sendable (_ fact: String, _ userId: String?, _ category: String?) async throws -> String) {
        self.storeHandler = storeHandler
    }

    public init() {
        self.storeHandler = { _, _, _ in
            throw GraphError.toolExecutionFailed(
                toolName: "memoryStore",
                errorDescription: "No persistent memory store has been configured."
            )
        }
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fact = json["fact"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "memoryStore", errorDescription: "Missing or invalid 'fact' parameter.")
        }

        let userId = json["userId"] as? String
        let category = json["category"] as? String
        return try await storeHandler(fact, userId, category)
    }
}

/// Built-in tool for reading and updating hierarchical Letta/MemGPT-style core working memory blocks (persona/scratchpad).
public struct CoreMemoryTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "coreMemory",
            description: "Inspects or updates hierarchical working memory blocks (such as user persona, agent profile, or task scratchpad).",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action to perform: 'get', 'set', or 'append'")
                    ]),
                    "blockName": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Target memory block identifier (e.g. 'persona', 'user_profile', 'scratchpad')")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("New content to set or append (required for 'set' and 'append')")
                    ])
                ]),
                "required": AnySendable([AnySendable("action"), AnySendable("blockName")])
            ]
        )
    }

    private let handler: @Sendable (String, String, String?) async throws -> String

    public init(handler: @escaping @Sendable (_ action: String, _ blockName: String, _ content: String?) async throws -> String) {
        self.handler = handler
    }

    public init(initialBlocks: [String: String] = [:]) {
        let storageActor = CoreMemoryStorageActor(initialBlocks: initialBlocks)
        self.handler = { action, blockName, content in
            await storageActor.perform(action: action, blockName: blockName, content: content)
        }
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String,
              let blockName = json["blockName"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "coreMemory", errorDescription: "Missing 'action' or 'blockName'.")
        }

        let content = json["content"] as? String
        return try await handler(action, blockName, content)
    }
}

/// Actor managing thread-safe in-memory storage for CoreMemoryTool.
private actor CoreMemoryStorageActor {
    private var storage: [String: String]

    init(initialBlocks: [String: String]) {
        self.storage = initialBlocks
    }

    func perform(action: String, blockName: String, content: String?) -> String {
        switch action.lowercased() {
        case "get":
            if let val = storage[blockName] {
                return val
            }
            return "Block '\(blockName)' is currently empty."
        case "set":
            let text = content ?? ""
            storage[blockName] = text
            return "Updated block '\(blockName)' successfully."
        case "append":
            let text = content ?? ""
            let existing = storage[blockName] ?? ""
            storage[blockName] = existing.isEmpty ? text : "\(existing)\n\(text)"
            return "Appended to block '\(blockName)' successfully."
        default:
            return "Unsupported action: '\(action)'. Valid actions: get, set, append."
        }
    }
}
