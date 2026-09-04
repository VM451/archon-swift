import Foundation
import SwiftData

@ModelActor
public actor FrontierQueueActor {
    private let robotsParser = RobotsParser()
    private var lastCrawlTimes = [String: Date]()
    private let defaultPolitenessDelay: TimeInterval = 1.0
    
    

    /// Enqueues new URLs to crawl if they haven't been crawled or queued yet.
    public func enqueue(urls: [URL], priority: Int = 0, parentURLString: String? = nil) throws {
        for url in urls {
            let urlString = url.absoluteString
            let domain = url.host?.lowercased() ?? ""
            
            // Check if URL is already in queue or scraped
            let nodeFetch = FetchDescriptor<CrawlNode>(
                predicate: #Predicate<CrawlNode> { $0.urlString == urlString }
            )
            let existingNodes = try modelContext.fetch(nodeFetch)
            
            let pageFetch = FetchDescriptor<ScrapedPage>(
                predicate: #Predicate<ScrapedPage> { $0.urlString == urlString }
            )
            let existingPages = try modelContext.fetch(pageFetch)
            
            if existingNodes.isEmpty && existingPages.isEmpty {
                let newNode = CrawlNode(urlString: urlString, status: .pending, priority: priority, domain: domain, parentURLString: parentURLString)
                modelContext.insert(newNode)
            }
        }
        try modelContext.save()
    }
    
    /// Fetches all nodes in the scheduler queue as Sendable objects.
    public func fetchAllNodes() throws -> [QueueNodeInfo] {
        let fetch = FetchDescriptor<CrawlNode>()
        let nodes = try modelContext.fetch(fetch)
        return nodes.map { node in
            QueueNodeInfo(
                urlString: node.urlString,
                status: node.statusValue,
                priority: node.priority,
                parentURLString: node.parentURLString,
                backoffUntil: node.backoffUntil
            )
        }
    }
    
    /// Dequeues the next crawlable URL, respecting robots.txt and domain rate limits.
    public func dequeueNext() async throws -> URL? {
        while true {
            // Fetch next pending node sorted by priority desc, addedAt asc
            var descriptor = FetchDescriptor<CrawlNode>()
            descriptor.fetchLimit = 50 // Fetch a batch to scan
            
            let nodes = try modelContext.fetch(descriptor)
            
            // Filter pending ones in-memory to keep code simple and clean
            let now = Date()
            let pendingNodes = nodes
                .filter { node in
                    node.status == .pending && (node.backoffUntil == nil || node.backoffUntil! <= now)
                }
                .sorted { (n1, n2) -> Bool in
                    if n1.priority != n2.priority {
                        return n1.priority > n2.priority
                    }
                    return n1.addedAt < n2.addedAt
                }
            
            guard let nextNode = pendingNodes.first else {
                return nil // No pending nodes left
            }
            
            guard let url = URL(string: nextNode.urlString) else {
                modelContext.delete(nextNode)
                try modelContext.save()
                continue
            }
            
            // 1. Verify robots.txt permission
            let isAllowed = await robotsParser.canCrawl(url)
            if !isAllowed {
                nextNode.status = .failed
                try modelContext.save()
                continue
            }
            
            // 2. Enforce Politeness / Domain Rate Limit
            let domain = nextNode.domain
            let robotsDelay = await robotsParser.crawlDelay(for: url)
            let delay = min(max(robotsDelay ?? defaultPolitenessDelay, 0), 300)
            
            if let lastCrawl = lastCrawlTimes[domain] {
                let elapsed = Date().timeIntervalSince(lastCrawl)
                if elapsed < delay {
                    let sleepTime = UInt64(min(max(delay - elapsed, 0), 300) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: sleepTime)
                }
            }
            
            // Update crawl status and save timestamp
            nextNode.status = .crawling
            nextNode.lastAttemptedAt = Date()
            lastCrawlTimes[domain] = Date()
            try modelContext.save()
            
            return url
        }
    }
    
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
                // Calculate backoff delay
                let delay: TimeInterval
                if let retryAfter = retryAfter {
                    delay = retryAfter
                } else {
                    // Exponential backoff: 2.0s, 4.0s, 8.0s...
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

/// Sendable representation of a crawl node inside the scheduler queue.
public struct QueueNodeInfo: Sendable, Codable {
    public let urlString: String
    public let status: String
    public let priority: Int
    public let parentURLString: String?
    public let backoffUntil: Date?
    
    public init(
        urlString: String,
        status: String,
        priority: Int,
        parentURLString: String? = nil,
        backoffUntil: Date? = nil
    ) {
        self.urlString = urlString
        self.status = status
        self.priority = priority
        self.parentURLString = parentURLString
        self.backoffUntil = backoffUntil
    }
}
