import Foundation

/// System events emitted by the Sandbox execution environment.
public enum SandboxEvent: Sendable, Codable, Equatable {
    case consoleLog(level: LogLevel, message: String, timestamp: Date)
    case uncaughtError(message: String, stackTrace: String?)
    case domMutation(summary: String, targetSelector: String?, timestamp: Date)
    case customMessage(name: String, payload: String)
    case toolCall(id: String, toolName: String, argumentsJSON: String)
    case lifecycle(LifecycleState)
    
    public enum LogLevel: String, Codable, Sendable, Equatable, Comparable {
        case debug
        case info
        case warning
        case error
        
        private var priority: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }
        
        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.priority < rhs.priority
        }
    }
    
    public enum LifecycleState: String, Codable, Sendable, Equatable {
        case initializing
        case ready
        case reloading
        case terminated
        case error
    }
    
    /// User-friendly string representation of the event.
    public var summary: String {
        switch self {
        case .consoleLog(let level, let message, _):
            return "[\(level.rawValue.uppercased())] \(message)"
        case .uncaughtError(let message, _):
            return "[ERROR] Uncaught: \(message)"
        case .domMutation(let summary, _, _):
            return "[DOM] \(summary)"
        case .customMessage(let name, let payload):
            return "[MESSAGE: \(name)] \(payload)"
        case .toolCall(let id, let toolName, let args):
            return "[TOOL_CALL: \(toolName) (id: \(id))] \(args)"
        case .lifecycle(let state):
            return "[LIFECYCLE] \(state.rawValue)"
        }
    }
}
