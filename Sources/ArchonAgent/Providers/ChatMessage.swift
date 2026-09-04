import Foundation

/// Role of a message in a conversation sequence.
public enum MessageRole: String, Codable, Sendable, Equatable {
    case system
    case developer
    case user
    case assistant
    case tool
}

/// Represents an invocable tool call requested by an LLM.
public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String = UUID().uuidString, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Represents an incoming chunk of a tool call in a streaming response.
public struct ToolCallChunk: Codable, Sendable, Equatable {
    public let index: Int
    public let id: String?
    public let name: String?
    public let argumentsDelta: String?

    public init(index: Int, id: String? = nil, name: String? = nil, argumentsDelta: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsDelta = argumentsDelta
    }
}

/// Represents a single message exchange in a multi-turn agent conversation.
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: MessageRole
    public let content: String
    public let toolCalls: [ToolCall]?
    public let toolCallId: String?
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.timestamp = timestamp
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: text)
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    public static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }

    public static func toolResult(_ content: String, toolCallId: String) -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallId: toolCallId)
    }
}
