import Foundation

/// Helper data holder containing the URL and text of a scraped page for citation extraction.
public struct ScrapedPageData: Sendable, Codable {
    public let url: URL
    public let text: String
    
    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}
