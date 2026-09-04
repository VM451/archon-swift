import Foundation

/// Result snapshot returned when an AI Agent applies a dynamic code patch or DOM mutation.
public struct AgentPatchResult: Sendable, Codable, Equatable {
    /// Indicates whether the patch evaluated without unhandled JavaScript exceptions.
    public let isSuccess: Bool
    
    /// Total wall-clock execution duration in milliseconds.
    public let executionTimeMs: Double
    
    /// Raw serialized JSON response or return value from the JavaScript runtime.
    public let rawOutput: String
    
    /// Optional error description if execution failed.
    public let errorDescription: String?
    
    public init(
        isSuccess: Bool,
        executionTimeMs: Double,
        rawOutput: String,
        errorDescription: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.executionTimeMs = executionTimeMs
        self.rawOutput = rawOutput
        self.errorDescription = errorDescription
    }
}
