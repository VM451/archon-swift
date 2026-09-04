import Foundation

/// Errors that can occur during sandbox lifecycle, execution, IPC bridging, or synchronization.
public enum SandboxError: Error, Sendable, CustomStringConvertible, Equatable {
    case serializationFailed(String)
    case executionFailed(String)
    case toolNotFound(String)
    case toolExecutionFailed(toolName: String, reason: String)
    case securityViolation(String)
    case cspViolation(String)
    case fileNotFound(String)
    case entryPointMissing(String)
    case invalidScheme(String)
    case memoryLimitExceeded(usedMB: Int, limitMB: Int)
    case engineDeallocated
    case timeout(String)
    case cloudKitSyncError(String)
    case crdtConflict(String)
    
    public var description: String {
        switch self {
        case .serializationFailed(let detail):
            return "SandboxError.serializationFailed: \(detail)"
        case .executionFailed(let detail):
            return "SandboxError.executionFailed: \(detail)"
        case .toolNotFound(let tool):
            return "SandboxError.toolNotFound: Tool '\(tool)' is not registered."
        case .toolExecutionFailed(let tool, let reason):
            return "SandboxError.toolExecutionFailed: Tool '\(tool)' failed with reason: \(reason)"
        case .securityViolation(let detail):
            return "SandboxError.securityViolation: \(detail)"
        case .cspViolation(let detail):
            return "SandboxError.cspViolation: \(detail)"
        case .fileNotFound(let path):
            return "SandboxError.fileNotFound: Virtual file not found at path '\(path)'."
        case .entryPointMissing(let path):
            return "SandboxError.entryPointMissing: Workspace entry point '\(path)' does not exist."
        case .invalidScheme(let scheme):
            return "SandboxError.invalidScheme: Unsupported URI scheme '\(scheme)'. Only sandbox:// and allowed schemes are supported."
        case .memoryLimitExceeded(let used, let limit):
            return "SandboxError.memoryLimitExceeded: Sandbox memory footprint (\(used)MB) exceeded limit of \(limit)MB."
        case .engineDeallocated:
            return "SandboxError.engineDeallocated: The underlying SandboxEngine was deallocated."
        case .timeout(let operation):
            return "SandboxError.timeout: Operation '\(operation)' timed out."
        case .cloudKitSyncError(let reason):
            return "SandboxError.cloudKitSyncError: \(reason)"
        case .crdtConflict(let detail):
            return "SandboxError.crdtConflict: \(detail)"
        }
    }
}
