import Foundation

public enum ArchonMemoryError: Error, LocalizedError, Equatable, Sendable {
    case memoryNotFound(UUID)
    case inputTooLarge(maxBytes: Int)
    case documentLoadFailed(String)
    case unsupportedDocumentFormat(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .memoryNotFound(let id): "Memory \(id.uuidString) was not found."
        case .inputTooLarge(let maxBytes): "Input exceeds the maximum supported size of \(maxBytes) bytes."
        case .documentLoadFailed(let reason): "Document loading failed: \(reason)"
        case .unsupportedDocumentFormat(let reason): "Unsupported document format: \(reason)"
        case .invalidConfiguration(let reason): "Invalid ArchonMemory configuration: \(reason)"
        }
    }
}
