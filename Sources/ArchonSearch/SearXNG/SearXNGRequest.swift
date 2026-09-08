import Foundation

/// Request parameters for querying a SearXNG meta-search engine instance.
public struct SearXNGRequest: Sendable, Codable, Equatable {
    public let query: String
    public let format: String
    public let categories: [String]?
    public let engines: [String]?
    public let pageno: Int
    public let timeRange: String?
    public let safeSearch: Int?

    enum CodingKeys: String, CodingKey {
        case query = "q"
        case format
        case categories
        case engines
        case pageno
        case timeRange = "time_range"
        case safeSearch = "safesearch"
    }

    public init(
        query: String,
        format: String = "json",
        categories: [String]? = nil,
        engines: [String]? = nil,
        pageno: Int = 1,
        timeRange: String? = nil,
        safeSearch: Int? = nil
    ) {
        self.query = query
        self.format = format
        self.categories = categories
        self.engines = engines
        self.pageno = max(1, pageno)
        self.timeRange = timeRange
        self.safeSearch = safeSearch
    }

    /// Builds the target search URL with query parameters appended.
    public func makeURL(baseURL: URL) -> URL? {
        let baseSearch = baseURL.appendingPathComponent("search")
        guard var components = URLComponents(url: baseSearch, resolvingAgainstBaseURL: true) else {
            return nil
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: "pageno", value: String(pageno))
        ]
        if let categories, !categories.isEmpty {
            items.append(URLQueryItem(name: "categories", value: categories.joined(separator: ",")))
        }
        if let engines, !engines.isEmpty {
            items.append(URLQueryItem(name: "engines", value: engines.joined(separator: ",")))
        }
        if let timeRange, !timeRange.isEmpty {
            items.append(URLQueryItem(name: "time_range", value: timeRange))
        }
        if let safeSearch {
            items.append(URLQueryItem(name: "safesearch", value: String(safeSearch)))
        }
        components.queryItems = items
        return components.url
    }
}
