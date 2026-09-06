import Foundation

/// Determines whether a registered tool may be invoked by untrusted page JavaScript.
public enum SandboxToolAuthorizationRequirement: String, Codable, Equatable, Sendable {
    case readOnly
    case explicitApproval
}

/// Capability policy for page-originated sandbox tool calls.
public struct SandboxToolAuthorizationPolicy: Equatable, Sendable {
    public let allowedToolNames: Set<String>

    public init(allowedToolNames: Set<String> = []) {
        self.allowedToolNames = allowedToolNames
    }

    public func allows(_ tool: any SandboxAgentTool) -> Bool {
        // Effect classification is descriptive only. Page-originated calls
        // always require an explicit host capability, including read-only
        // tools, because a registered closure remains host authority.
        allowedToolNames.contains(tool.name)
    }
}

/// Protocol defining an actionable native tool exposed from the Host/Agent to the JavaScript Sandbox runtime (and vice-versa).
public protocol SandboxAgentTool: Sendable {
    /// The unique identifier of the tool (e.g. "Calculator", "FetchDeviceLocation", "GenerateChart").
    var name: String { get }
    
    /// Natural language description of what the tool accomplishes, used by LLM agents for tool selection.
    var description: String { get }
    
    /// JSON Schema string representing the tool's parameter structure.
    var parametersSchemaJSON: String { get }

    /// The host-granted effect level for calls originating in page JavaScript.
    var authorizationRequirement: SandboxToolAuthorizationRequirement { get }
    
    /// Executes the tool asynchronously with input JSON arguments and returns JSON string results.
    func execute(argumentsJSON: String) async throws -> String
}

/// A lightweight closure-based implementation of `SandboxAgentTool`.
public struct ClosureAgentTool: SandboxAgentTool {
    public let name: String
    public let description: String
    public let parametersSchemaJSON: String
    public let authorizationRequirement: SandboxToolAuthorizationRequirement
    private let handler: @Sendable (String) async throws -> String
    
    public init(
        name: String,
        description: String,
        parametersSchemaJSON: String = "{}",
        authorizationRequirement: SandboxToolAuthorizationRequirement = .explicitApproval,
        handler: @escaping @Sendable (String) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
        self.authorizationRequirement = authorizationRequirement
        self.handler = handler
    }
    
    public func execute(argumentsJSON: String) async throws -> String {
        try await handler(argumentsJSON)
    }
}
