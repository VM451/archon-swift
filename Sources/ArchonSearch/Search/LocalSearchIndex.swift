import Foundation

public struct SearchProviderCapabilities: Codable, Equatable, Sendable {
    public let supportsOffline: Bool
    public let supportsQueryRewriting: Bool
    public let supportsStructuredExtraction: Bool
    public let isNetworkDependent: Bool

    public init(
        supportsOffline: Bool,
        supportsQueryRewriting: Bool = false,
        supportsStructuredExtraction: Bool = false,
        isNetworkDependent: Bool
    ) {
        self.supportsOffline = supportsOffline
        self.supportsQueryRewriting = supportsQueryRewriting
        self.supportsStructuredExtraction = supportsStructuredExtraction
        self.isNetworkDependent = isNetworkDependent
    }
}

public struct LocalSearchDocument: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let content: String
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        content: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.content = content
        self.updatedAt = updatedAt
    }
}

public enum LocalSearchIndexError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimit(Int)
    case invalidStorageURL

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let limit): "Local search limit is invalid: \(limit)."
        case .invalidStorageURL: "The local search index storage URL is invalid."
        }
    }
}

/// A small, deterministic, file-backed local corpus index. It intentionally
/// uses no server or cloud service and can be replaced behind SearchProvider.
public actor LocalSearchIndex {
    private var documents: [UUID: LocalSearchDocument] = [:]
    private let storageURL: URL?

    public init(storageURL: URL? = nil) throws {
        self.storageURL = storageURL
        if let storageURL {
            guard storageURL.isFileURL else { throw LocalSearchIndexError.invalidStorageURL }
            if let data = try? Data(contentsOf: storageURL) {
                documents = try JSONDecoder().decode([UUID: LocalSearchDocument].self, from: data)
            }
        }
    }

    public var count: Int { documents.count }

    public func upsert(_ document: LocalSearchDocument) throws {
        documents[document.id] = document
        try persist()
    }

    public func remove(id: UUID) throws -> Bool {
        let removed = documents.removeValue(forKey: id) != nil
        if removed { try persist() }
        return removed
    }

    public func rebuild(_ newDocuments: [LocalSearchDocument]) throws {
        documents = Dictionary(uniqueKeysWithValues: newDocuments.map { ($0.id, $0) })
        try persist()
    }

    public func search(query: String, limit: Int = 10) throws -> [SearchResult] {
        guard (0...500).contains(limit) else { throw LocalSearchIndexError.invalidLimit(limit) }
        guard limit > 0 else { return [] }
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }

        return documents.values.compactMap { document in
            let haystack = "\(document.title) \(document.content)".lowercased()
            let score = terms.reduce(into: 0) { total, term in
                if document.title.lowercased().contains(term) { total += 3 }
                if haystack.contains(term) { total += 1 }
            }
            guard score > 0 else { return nil }
            let snippet = Self.snippet(for: document.content, terms: terms)
            return SearchResult(
                id: document.id,
                url: document.url,
                title: document.title,
                snippet: snippet,
                highlights: terms.filter { haystack.contains($0) }
            )
        }
        .sorted {
            if $0.highlights.count != $1.highlights.count {
                return $0.highlights.count > $1.highlights.count
            }
            return $0.url.absoluteString < $1.url.absoluteString
        }
        .prefix(limit)
        .map { $0 }
    }

    private func persist() throws {
        guard let storageURL else { return }
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(documents)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func snippet(for content: String, terms: [String]) -> String {
        let lower = content.lowercased()
        let start = terms.compactMap { lower.range(of: $0)?.lowerBound }
            .min()
            .map { lower.distance(from: lower.startIndex, to: $0) } ?? 0
        let prefix = content.index(content.startIndex, offsetBy: min(start, content.count), limitedBy: content.endIndex) ?? content.endIndex
        let end = content.index(prefix, offsetBy: 240, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[prefix..<end])
    }
}

public struct LocalSearchIndexProvider: SearchProvider, Sendable {
    public let providerID: String
    public let capabilities = SearchProviderCapabilities(
        supportsOffline: true,
        supportsQueryRewriting: false,
        supportsStructuredExtraction: false,
        isNetworkDependent: false
    )
    private let index: LocalSearchIndex

    public init(index: LocalSearchIndex, providerID: String = "archon.local-search") {
        self.index = index
        self.providerID = providerID
    }

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        try Task.checkCancellation()
        guard request.networkPolicy == .localOnly else {
            throw SearchError.localOnlyRequiresLocalSource
        }
        let results = try await index.search(query: request.query, limit: min(max(request.maxResults, 0), 500))
        return SearchResponse(
            results: results,
            providerID: providerID,
            networkPolicy: .localOnly,
            usedNetwork: false
        )
    }
}
