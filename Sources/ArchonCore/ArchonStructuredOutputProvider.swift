import Foundation

/// Shared structured-output boundary used by independent Archon products.
///
/// Providers may implement this directly, while richer agent providers can
/// supply a default JSON-decoding implementation in their own product. Keeping
/// this contract in ArchonCore avoids making ArchonMemory depend on ArchonAgent.
public protocol ArchonStructuredOutputProvider: Sendable {
    func generateStructuredOutput<T: Decodable & Sendable>(
        prompt: String,
        responseSchema: T.Type
    ) async throws -> T
}
