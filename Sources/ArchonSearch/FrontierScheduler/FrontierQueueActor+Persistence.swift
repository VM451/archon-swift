import Foundation
import SwiftData

extension FrontierQueueActor {
    public func markCompleted(urlString: String) throws {
        let fetch = FetchDescriptor<CrawlNode>(
            predicate: #Predicate<CrawlNode> { $0.urlString == urlString }
        )
        if let node = try modelContext.fetch(fetch).first {
            node.status = .completed
            try modelContext.save()
        }
    }

    public func markFailed(urlString: String, retryAfter: TimeInterval? = nil) throws {
        let fetch = FetchDescriptor<CrawlNode>(
            predicate: #Predicate<CrawlNode> { $0.urlString == urlString }
        )
        if let node = try modelContext.fetch(fetch).first {
            node.retryCount += 1
            if node.retryCount >= 3 {
                node.status = .failed
            } else {
                node.status = .pending
                let delay: TimeInterval
                if let retryAfter = retryAfter {
                    delay = retryAfter
                } else {
                    delay = pow(2.0, Double(node.retryCount))
                }
                node.backoffUntil = Date().addingTimeInterval(delay)
            }
            try modelContext.save()
        }
    }

    /// Saves a scraped page's details to the SwiftData store.
    public func savePage(urlString: String, html: String, text: String, title: String, signature: [Int64]) throws {
        let page = ScrapedPage(urlString: urlString, rawHTML: html, scrapedText: text, title: title, minHashSignature: signature)
        modelContext.insert(page)
        try modelContext.save()
    }

    /// Checks if a page is a duplicate of any already crawled page using MinHash Jaccard similarity.
    public func isDuplicate(signature: [Int64], threshold: Double = 0.85) throws -> Bool {
        let fetch = FetchDescriptor<ScrapedPage>()
        let scrapedPages = try modelContext.fetch(fetch)

        for page in scrapedPages {
            let sim = MinHashDeduplicator.jaccardSimilarity(sig1: signature, sig2: page.minHashSignature)
            if sim >= threshold {
                return true
            }
        }

        return false
    }
}
