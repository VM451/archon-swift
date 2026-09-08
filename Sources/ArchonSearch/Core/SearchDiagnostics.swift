import Foundation

/// Telemetry and diagnostics collected during an ArchonSearch query or crawl session.
public struct SearchDiagnostics: Sendable, Codable, Equatable {
    public var searchDuration: TimeInterval
    public var engineResults: [String: Int]
    public var urlFetchCount: Int
    public var cacheHits: Int
    public var extractionMethod: String
    public var characterEstimate: Int
    public var tokenEstimate: Int
    public var errors: [String]
    
    public init(
        searchDuration: TimeInterval = 0.0,
        engineResults: [String: Int] = [:],
        urlFetchCount: Int = 0,
        cacheHits: Int = 0,
        extractionMethod: String = "native",
        characterEstimate: Int = 0,
        tokenEstimate: Int = 0,
        errors: [String] = []
    ) {
        self.searchDuration = searchDuration
        self.engineResults = engineResults
        self.urlFetchCount = urlFetchCount
        self.cacheHits = cacheHits
        self.extractionMethod = extractionMethod
        self.characterEstimate = characterEstimate
        self.tokenEstimate = tokenEstimate
        self.errors = errors
    }
    
    /// Records an error string into diagnostics telemetry.
    public mutating func recordError(_ error: any Error) {
        errors.append(String(describing: error))
    }
    
    /// Records a cache hit event.
    public mutating func recordCacheHit() {
        cacheHits += 1
    }
    
    /// Records a network URL fetch event.
    public mutating func recordFetch() {
        urlFetchCount += 1
    }
}
