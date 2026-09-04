import Foundation
import SwiftData

@Model
public final class ScrapedPage {
    @Attribute(.unique)
    public var urlString: String
    
    public var rawHTML: String
    public var scrapedText: String
    public var title: String
    public var minHashSignature: [Int64]
    public var scrapedAt: Date
    
    public init(
        urlString: String,
        rawHTML: String,
        scrapedText: String,
        title: String,
        minHashSignature: [Int64],
        scrapedAt: Date = Date()
    ) {
        self.urlString = urlString
        self.rawHTML = rawHTML
        self.scrapedText = scrapedText
        self.title = title
        self.minHashSignature = minHashSignature
        self.scrapedAt = scrapedAt
    }
}
