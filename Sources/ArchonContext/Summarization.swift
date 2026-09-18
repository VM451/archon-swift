import Foundation

/// Host-supplied summarizer seam. Implementations run on-device, in-process,
/// and receive already-ordered fragments. Returned fragments keep their own
/// provenance and trust; the builder re-applies deterministic ordering.
public protocol ContextSummarizer: Sendable {
    func summarize(_ fragments: [ContextFragment], budget: ContextBudget) async throws -> [ContextFragment]
}

/// Typed summarization failures. Unavailable summarizers fall back to
/// truncation when the caller opts in.
public enum ContextSummarizationError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Context summarizer is unavailable: \(detail)"
        case .failed(let detail):
            "Context summarization failed: \(detail)"
        }
    }
}
