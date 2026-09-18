import Foundation

public enum ArchonMemoryError: Error, LocalizedError, Equatable, Sendable {
    case memoryNotFound(UUID)
    case inputTooLarge(maxBytes: Int)
    case documentLoadFailed(String)
    case unsupportedDocumentFormat(String)
    case invalidConfiguration(String)
    case invalidSearchRequest(String)
    case invalidCompetitiveResearch(String)
    case supersessionTargetInvalid(UUID)
    case supersessionChainBroken(UUID)

    public var errorDescription: String? {
        switch self {
        case .memoryNotFound(let id): "Memory \(id.uuidString) was not found."
        case .inputTooLarge(let maxBytes): "Input exceeds the maximum supported size of \(maxBytes) bytes."
        case .documentLoadFailed(let reason): "Document loading failed: \(reason)"
        case .unsupportedDocumentFormat(let reason): "Unsupported document format: \(reason)"
        case .invalidConfiguration(let reason): "Invalid ArchonMemory configuration: \(reason)"
        case .invalidSearchRequest(let reason): "Invalid memory search request: \(reason)"
        case .invalidCompetitiveResearch(let reason): "Invalid competitive research: \(reason)"
        case .supersessionTargetInvalid(let id): "Memory \(id.uuidString) cannot be superseded because it is missing, deleted, or expired."
        case .supersessionChainBroken(let id): "Supersession chain is broken at memory \(id.uuidString): the successor is missing or the chain cycles."
        }
    }
}
