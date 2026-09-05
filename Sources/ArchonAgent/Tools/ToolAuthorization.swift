import Foundation

/// Declares whether a tool may be called by an untrusted model response without
/// an application-level capability grant.
public enum ToolAuthorizationRequirement: String, Codable, Sendable {
    case readOnly
    case explicitApproval
}

/// Fail-closed capability policy for model-originated tool calls.
public struct ToolAuthorizationPolicy: Sendable {
    private let allowAllTools: Bool
    private let explicitlyAllowedToolNames: Set<String>

    /// The default policy permits read-only tools and requires an explicit
    /// allowlist entry for tools with side effects, device access, or network egress.
    public init(allowedToolNames: Set<String> = []) {
        self.allowAllTools = false
        self.explicitlyAllowedToolNames = allowedToolNames
    }

    /// Compatibility escape hatch for an application that has independently
    /// authenticated and authorized the complete registry.
    public static let allowAll = ToolAuthorizationPolicy(allowAllTools: true)

    func allows(_ tool: any Tool) -> Bool {
        allowAllTools || tool.authorizationRequirement == .readOnly || explicitlyAllowedToolNames.contains(tool.definition.name)
    }

    private init(allowAllTools: Bool) {
        self.allowAllTools = allowAllTools
        self.explicitlyAllowedToolNames = []
    }
}

public extension Tool {
    // Custom tools are untrusted by default. Read-only classification must be
    // granted explicitly by the tool implementation or the registry.
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension FileSystemTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension MemoryStoreTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension CoreMemoryTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension SandboxPatchTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension WebSearchTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension WebContentsTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension DeepResearchAgentTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}

public extension CalendarTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension RemindersTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension NotesTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension ContactsTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension MailTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension FilesTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension MapsTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension SystemControlTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
public extension TimerTool {
    var authorizationRequirement: ToolAuthorizationRequirement { .explicitApproval }
}
