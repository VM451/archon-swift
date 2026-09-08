import Foundation

/// Codable raw search result item returned by SearXNG JSON API.
public struct RawSearXNGResult: Sendable, Codable, Equatable {
    public let url: String
    public let title: String
    public let content: String?
    public let engine: String?
    public let score: Double?
    public let publishedDate: String?

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case content
        case engine
        case score
        case publishedDate
    }

    public init(
        url: String,
        title: String,
        content: String? = nil,
        engine: String? = nil,
        score: Double? = nil,
        publishedDate: String? = nil
    ) {
        self.url = url
        self.title = title
        self.content = content
        self.engine = engine
        self.score = score
        self.publishedDate = publishedDate
    }
}

/// An infobox block optionally returned in SearXNG search responses.
public struct RawSearXNGInfobox: Sendable, Codable, Equatable {
    public let infobox: String?
    public let id: String?
    public let content: String?

    public init(infobox: String? = nil, id: String? = nil, content: String? = nil) {
        self.infobox = infobox
        self.id = id
        self.content = content
    }
}

/// Top-level response payload decoded from SearXNG's JSON endpoint.
public struct SearXNGResponse: Sendable, Codable, Equatable {
    public let query: String
    public let numberOfResults: Int?
    public let results: [RawSearXNGResult]
    public let answers: [String]
    public let infoboxes: [RawSearXNGInfobox]
    public let suggestions: [String]

    enum CodingKeys: String, CodingKey {
        case query
        case numberOfResults = "number_of_results"
        case results
        case answers
        case infoboxes
        case suggestions
    }

    public init(
        query: String,
        numberOfResults: Int? = nil,
        results: [RawSearXNGResult] = [],
        answers: [String] = [],
        infoboxes: [RawSearXNGInfobox] = [],
        suggestions: [String] = []
    ) {
        self.query = query
        self.numberOfResults = numberOfResults
        self.results = results
        self.answers = answers
        self.infoboxes = infoboxes
        self.suggestions = suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decode(String.self, forKey: .query)
        self.numberOfResults = try container.decodeIfPresent(Int.self, forKey: .numberOfResults)
        self.results = try container.decodeIfPresent([RawSearXNGResult].self, forKey: .results) ?? []
        self.answers = try container.decodeIfPresent([String].self, forKey: .answers) ?? []
        self.infoboxes = try container.decodeIfPresent([RawSearXNGInfobox].self, forKey: .infoboxes) ?? []
        self.suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
    }
}
