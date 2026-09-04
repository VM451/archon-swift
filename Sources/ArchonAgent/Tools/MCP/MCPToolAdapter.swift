import Foundation

/// JSON representation of an MCP (Model Context Protocol) tool schema.
public struct MCPToolSchema: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchema: [String: AnySendable]

    public init(name: String, description: String, inputSchema: [String: AnySendable]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public func validate(argumentsJSON: String) throws {
        try ToolDefinition(
            name: name,
            description: description,
            parametersJSONSchema: inputSchema
        ).validate(argumentsJSON: argumentsJSON)
    }
}

/// Adapter converting native ArchonAgent tools to and from standard Model Context Protocol (MCP) format.
public struct MCPToolAdapter: Sendable {
    public init() {}

    /// Converts a native ArchonAgent Tool into an MCP Tool Schema.
    public static func toMCPSchema(tool: any Tool) -> MCPToolSchema {
        let def = tool.definition
        return MCPToolSchema(
            name: def.name,
            description: def.description,
            inputSchema: def.parametersJSONSchema
        )
    }

    /// Wraps an external MCP tool invocation closure as a native ArchonAgent Tool.
    public static func fromMCP(
        schema: MCPToolSchema,
        executor: @escaping @Sendable (String) async throws -> String
    ) -> any Tool {
        ClosureTool(
            name: schema.name,
            description: schema.description,
            parametersSchema: schema.inputSchema,
            handler: { argumentsJSON in
                try schema.validate(argumentsJSON: argumentsJSON)
                return try await executor(argumentsJSON)
            }
        )
    }
}

/// Server Bridge exposing ArchonAgent tools over standard Model Context Protocol (MCP) discovery schemas.
public final class MCPServerBridge: Sendable {
    public let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Returns all registered tools formatted as an MCP tool list response.
    public func listTools() -> [MCPToolSchema] {
        registry.definitions().map { def in
            MCPToolSchema(
                name: def.name,
                description: def.description,
                inputSchema: def.parametersJSONSchema
            )
        }
    }

    /// Handles an incoming MCP `tools/call` invocation request.
    public func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = registry.tool(named: name) else {
            throw GraphError.toolExecutionFailed(toolName: name, errorDescription: "MCP tool '\(name)' not found.")
        }
        try tool.definition.validate(argumentsJSON: argumentsJSON)
        return try await tool.call(argumentsJSON: argumentsJSON)
    }
}

/// Client Bridge that imports external MCP tools into a local ArchonAgent ToolRegistry.
public final class MCPClientBridge: Sendable {
    private let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Imports and registers an external MCP tool into the local registry.
    public func registerMCPTool(
        schema: MCPToolSchema,
        invoker: @escaping @Sendable (String) async throws -> String
    ) {
        // Keep the MCP name for API compatibility; ToolRegistry rejects a
        // collision instead of allowing an external tool to replace a trusted one.
        let tool = MCPToolAdapter.fromMCP(schema: schema, executor: invoker)
        _ = registry.register(tool)
    }
}
