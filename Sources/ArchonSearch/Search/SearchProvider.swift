import Foundation

/// Declares whether a search request may cross the application's network boundary.
///
/// `localOnly` is a hard policy. A provider must reject a request that names a
/// network discovery source instead of silently falling back to the network.
public enum SearchNetworkPolicy: String, Codable, Hashable, Sendable {
    case localOnly
    case networkAllowed
}

/// Provider-neutral search input shared by local corpus and cloud adapters.
public struct SearchRequest: Codable, Hashable, Sendable {
    public let query: String
    public let source: DiscoverySource
    public let maxResults: Int
    public let maxSnippetCharacters: Int
    public let maxHighlights: Int
    public let livecrawl: LivecrawlPolicy
    public let latency: TimeInterval?
    public let networkPolicy: SearchNetworkPolicy

    public init(
        query: String,
        source: DiscoverySource,
        maxResults: Int = 10,
        maxSnippetCharacters: Int = 300,
        maxHighlights: Int = 3,
        livecrawl: LivecrawlPolicy = .fast,
        latency: TimeInterval? = nil,
        networkPolicy: SearchNetworkPolicy = .localOnly
    ) {
        self.query = query
        self.source = source
        self.maxResults = maxResults
        self.maxSnippetCharacters = maxSnippetCharacters
        self.maxHighlights = maxHighlights
        self.livecrawl = livecrawl
        self.latency = latency
        self.networkPolicy = networkPolicy
    }

    /// Whether the discovery source can be fulfilled without a network request.
    public var isLocalSource: Bool {
        if case .localWorkspace = source { return true }
        return false
    }
}

/// Provider-neutral search result envelope.
public struct SearchResponse: Codable, Hashable, Sendable {
    public let results: [SearchResult]
    public let providerID: String
    public let networkPolicy: SearchNetworkPolicy
    /// True when this response was produced by a network-dependent source.
    public let usedNetwork: Bool

    public init(
        results: [SearchResult],
        providerID: String,
        networkPolicy: SearchNetworkPolicy,
        usedNetwork: Bool
    ) {
        self.results = results
        self.providerID = providerID
        self.networkPolicy = networkPolicy
        self.usedNetwork = usedNetwork
    }
}

/// Archon-owned contract for both offline search and explicit cloud adapters.
/// Vendor SDK types and credentials must remain behind conforming adapters.
public protocol SearchProvider: Sendable {
    var providerID: String { get }
    func search(_ request: SearchRequest) async throws -> SearchResponse
}

/// Adapts the existing Archon search engine to the provider-neutral contract.
///
/// Local-only requests are accepted only for `localWorkspace`. This wrapper is
/// intentionally strict because a generic `ArchonSearch` instance also knows
/// how to query public web sources; callers must opt into that boundary through
/// `networkAllowed`.
public struct ArchonSearchProvider: SearchProvider, Sendable {
    public let providerID: String
    private let engine: ArchonSearch

    public init(engine: ArchonSearch = ArchonSearch(), providerID: String = "archon.search") {
        self.engine = engine
        self.providerID = providerID
    }

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        try Task.checkCancellation()
        if request.networkPolicy == .localOnly && !request.isLocalSource {
            throw SearchError.localOnlyRequiresLocalSource
        }
        if request.networkPolicy == .localOnly,
           request.isLocalSource,
           case .full = request.livecrawl {
            throw SearchError.localOnlyRequiresStaticLocalCrawl
        }

        let results = try await engine.search(
            query: request.query,
            source: request.source,
            maxResults: request.maxResults,
            maxSnippetCharacters: request.maxSnippetCharacters,
            maxHighlights: request.maxHighlights,
            livecrawl: request.livecrawl,
            latency: request.latency
        )
        try Task.checkCancellation()

        return SearchResponse(
            results: results,
            providerID: providerID,
            networkPolicy: request.networkPolicy,
            usedNetwork: !request.isLocalSource
        )
    }
}
