import Foundation

/// Represents the metadata definition of a tool exposed to Foundation Models and LLM agents.
public struct FoundationModelToolDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parametersSchemaJSON: String
    
    public init(name: String, description: String, parametersSchemaJSON: String = "{}") {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }
}

/// Thread-safe actor managing the registration, parameter validation, and execution of AI Agent tools.
public actor ToolRegistryActor {
    private var tools: [String: any SandboxAgentTool] = [:]
    
    public init() {}
    
    /// Registers a tool in the active registry.
    public func register(_ tool: any SandboxAgentTool) {
        tools[tool.name] = tool
    }
    
    /// Removes a tool by name.
    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }
    
    /// Retrieves all registered tool names.
    public func registeredToolNames() -> [String] {
        Array(tools.keys)
    }
    
    /// Returns a specific tool by name.
    public func tool(named name: String) -> (any SandboxAgentTool)? {
        tools[name]
    }
    
    /// Generates a list of tool definitions formatted for Foundation Models.
    public func exportFoundationModelToolDefinitions() -> [FoundationModelToolDefinition] {
        return tools.values.map { tool in
            FoundationModelToolDefinition(
                name: tool.name,
                description: tool.description,
                parametersSchemaJSON: tool.parametersSchemaJSON
            )
        }
    }
    
    /// Executes a registered tool by name with raw JSON arguments.
    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard let tool = tools[toolName] else {
            throw SandboxError.toolNotFound(toolName)
        }
        do {
            return try await tool.execute(argumentsJSON: argumentsJSON)
        } catch {
            throw SandboxError.toolExecutionFailed(toolName: toolName, reason: error.localizedDescription)
        }
    }
}
