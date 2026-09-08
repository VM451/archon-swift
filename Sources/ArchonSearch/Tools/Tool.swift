import Foundation

/// Provider-neutral protocol defining an invocable AI agent tool.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    func call(argumentsJSON: String) async throws -> String
}
