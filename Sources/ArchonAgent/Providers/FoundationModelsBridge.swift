import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bridge connecting Apple's Foundation Models framework (`LanguageModel` / `LanguageModelSession`)
/// with Archon's Agent Graph runtime, tools, memory, and checkpointers.
public final class FoundationModelsBridge: Sendable {

    /// Wraps any Archon `LLMProvider` into an Apple Foundation Models compatible provider identifier.
    public static func describe(provider: any LLMProvider) -> String {
        "FoundationModels.Bridge[\(provider.id)] - Capabilities: \(provider.capabilities.maxContextTokens) tokens, onDevice: \(provider.capabilities.isOnDevice)"
    }

    /// Translates an Archon prompt sequence into a flat system/user formatted turn for `LanguageModelSession`.
    public static func formatTranscript(for prompt: [ChatMessage]) -> (systemInstruction: String?, userPrompt: String) {
        var systemInstructions: [String] = []
        var conversationTurns: [String] = []

        for message in prompt {
            switch message.role {
            case .system, .developer:
                systemInstructions.append(message.content)
            case .user:
                conversationTurns.append("User: \(message.content)")
            case .assistant:
                conversationTurns.append("Assistant: \(message.content)")
            case .tool:
                conversationTurns.append("Tool Result: \(message.content)")
            }
        }

        let systemText = systemInstructions.isEmpty ? nil : systemInstructions.joined(separator: "\n\n")
        let userText = conversationTurns.joined(separator: "\n")

        return (systemInstruction: systemText, userPrompt: userText)
    }

   /// Converts an array of Archon `ToolDefinition`s into standard JSON function signatures compatible with Apple Foundation Models tool dispatch.
    /// Exports Archon tool metadata for an application-owned typed adapter.
    ///
    /// This is metadata only. Foundation Models requires concrete `Tool`
    /// implementations with `Generable` argument types, so callers must not
    /// treat this JSON as executable tool registration.
    public static func exportToolsSchema(from tools: [ToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parametersJSONSchema
            ]
        }
    }
}
