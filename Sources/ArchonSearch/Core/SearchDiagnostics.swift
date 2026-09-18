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
    /// True when the embedding rerank path applied at least one semantic score.
    public var usedSemanticRerank: Bool

    public init(
        searchDuration: TimeInterval = 0.0,
        engineResults: [String: Int] = [:],
        urlFetchCount: Int = 0,
        cacheHits: Int = 0,
        extractionMethod: String = "native",
        characterEstimate: Int = 0,
        tokenEstimate: Int = 0,
        errors: [String] = [],
        usedSemanticRerank: Bool = false
    ) {
        self.searchDuration = searchDuration
        self.engineResults = engineResults
        self.urlFetchCount = urlFetchCount
        self.cacheHits = cacheHits
        self.extractionMethod = extractionMethod
        self.characterEstimate = characterEstimate
        self.tokenEstimate = tokenEstimate
        self.errors = errors
        self.usedSemanticRerank = usedSemanticRerank
    }

    private enum CodingKeys: String, CodingKey {
        case searchDuration, engineResults, urlFetchCount, cacheHits
        case extractionMethod, characterEstimate, tokenEstimate, errors
        case usedSemanticRerank
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.searchDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .searchDuration) ?? 0.0
        self.engineResults = try container.decodeIfPresent([String: Int].self, forKey: .engineResults) ?? [:]
        self.urlFetchCount = try container.decodeIfPresent(Int.self, forKey: .urlFetchCount) ?? 0
        self.cacheHits = try container.decodeIfPresent(Int.self, forKey: .cacheHits) ?? 0
        self.extractionMethod = try container.decodeIfPresent(String.self, forKey: .extractionMethod) ?? "native"
        self.characterEstimate = try container.decodeIfPresent(Int.self, forKey: .characterEstimate) ?? 0
        self.tokenEstimate = try container.decodeIfPresent(Int.self, forKey: .tokenEstimate) ?? 0
        self.errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        self.usedSemanticRerank = try container.decodeIfPresent(Bool.self, forKey: .usedSemanticRerank) ?? false
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
