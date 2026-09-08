import Foundation

/// Markdown representation containing raw and heuristic/fit markdown formats.
public struct Crawl4AIMarkdown: Sendable, Codable, Hashable {
    public let rawMarkdown: String?
    public let fitMarkdown: String?

    enum CodingKeys: String, CodingKey {
        case rawMarkdown = "raw_markdown"
        case fitMarkdown = "fit_markdown"
    }

    public init(rawMarkdown: String? = nil, fitMarkdown: String? = nil) {
        self.rawMarkdown = rawMarkdown
        self.fitMarkdown = fitMarkdown
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.rawMarkdown = try container.decodeIfPresent(String.self, forKey: .rawMarkdown)
            self.fitMarkdown = try container.decodeIfPresent(String.self, forKey: .fitMarkdown)
        } else if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            self.rawMarkdown = str
            self.fitMarkdown = str
        } else {
            self.rawMarkdown = nil
            self.fitMarkdown = nil
        }
    }
}

/// Codable representation of Crawl4AI /crawl response.
public struct Crawl4AIResponse: Sendable, Codable, Hashable {
    public let url: String
    public let success: Bool
    public let statusCode: Int?
    public let html: String?
    public let fitHtml: String?
    public let markdown: Crawl4AIMarkdown?
    public let metadata: [String: String]?
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case url
        case success
        case statusCode = "status_code"
        case html
        case fitHtml = "fit_html"
        case markdown
        case metadata
        case errorMessage = "error_message"
    }

    public init(
        url: String,
        success: Bool,
        statusCode: Int? = nil,
        html: String? = nil,
        fitHtml: String? = nil,
        markdown: Crawl4AIMarkdown? = nil,
        metadata: [String: String]? = nil,
        errorMessage: String? = nil
    ) {
        self.url = url
        self.success = success
        self.statusCode = statusCode
        self.html = html
        self.fitHtml = fitHtml
        self.markdown = markdown
        self.metadata = metadata
        self.errorMessage = errorMessage
    }
}
