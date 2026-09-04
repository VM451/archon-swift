import Foundation

/// Protocol defining an actionable native tool exposed from the Host/Agent to the JavaScript Sandbox runtime (and vice-versa).
public protocol SandboxAgentTool: Sendable {
    /// The unique identifier of the tool (e.g. "Calculator", "FetchDeviceLocation", "GenerateChart").
    var name: String { get }
    
    /// Natural language description of what the tool accomplishes, used by LLM agents for tool selection.
    var description: String { get }
    
    /// JSON Schema string representing the tool's parameter structure.
    var parametersSchemaJSON: String { get }
    
    /// Executes the tool asynchronously with input JSON arguments and returns JSON string results.
    func execute(argumentsJSON: String) async throws -> String
}

/// A lightweight closure-based implementation of `SandboxAgentTool`.
public struct ClosureAgentTool: SandboxAgentTool {
    public let name: String
    public let description: String
    public let parametersSchemaJSON: String
    private let handler: @Sendable (String) async throws -> String
    
    public init(
        name: String,
        description: String,
        parametersSchemaJSON: String = "{}",
        handler: @escaping @Sendable (String) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
        self.handler = handler
    }
    
    public func execute(argumentsJSON: String) async throws -> String {
        try await handler(argumentsJSON)
    }
}
