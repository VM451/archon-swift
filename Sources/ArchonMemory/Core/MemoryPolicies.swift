import Foundation

/// Controls automatic memory extraction without silently enabling destructive
/// mutations.
public struct MemoryExtractionPolicy: Codable, Equatable, Sendable {
    public let maxCandidates: Int
    public let enableGraphExtraction: Bool
    public let allowAutomaticDeletion: Bool

    public init(
        maxCandidates: Int = 10,
        enableGraphExtraction: Bool = true,
        allowAutomaticDeletion: Bool = false
    ) {
        self.maxCandidates = max(0, maxCandidates)
        self.enableGraphExtraction = enableGraphExtraction
        self.allowAutomaticDeletion = allowAutomaticDeletion
    }

    public static let standard = MemoryExtractionPolicy()
}

/// Bounds retrieval at the application boundary. Scope and temporal filters
/// remain represented by `MemoryFilter` and are applied by storage.
public struct MemoryRetrievalPolicy: Codable, Equatable, Sendable {
    public let maximumResults: Int
    public let includeDeleted: Bool

    public init(maximumResults: Int = 100, includeDeleted: Bool = false) {
        self.maximumResults = max(0, maximumResults)
        self.includeDeleted = includeDeleted
    }

    public static let standard = MemoryRetrievalPolicy()
}
