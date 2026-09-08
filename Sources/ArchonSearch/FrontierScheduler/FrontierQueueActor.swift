import Foundation
import SwiftData
import ArchonCore

@ModelActor
public actor FrontierQueueActor {
    private let robotsParser = RobotsParser()
    private var lastCrawlTimes = [String: Date]()
    private let defaultPolitenessDelay: TimeInterval = 1.0
    
    

    /// Enqueues new URLs to crawl if they haven't been crawled or queued yet.
    public func enqueue(
        urls: [URL],
        priority: Int = 0,
        parentURLString: String? = nil,
        localWorkspaceRoots: [URL] = []
    ) throws {
        for url in urls {
            guard isPermitted(url, localWorkspaceRoots: localWorkspaceRoots) else {
                continue
            }
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
    public func dequeueNext(localWorkspaceRoots: [URL] = []) async throws -> URL? {
        while true {
            // Fetch next pending node sorted by priority desc, addedAt asc
            var descriptor = FetchDescriptor<CrawlNode>()
            descriptor.fetchLimit = 50 // Fetch a batch to scan
            
            let nodes = try modelContext.fetch(descriptor)
            
            // Filter pending ones in-memory to keep code simple and clean
            let now = Date()
            let pendingNodes = nodes
                .filter { node in
                    node.status == .pending && (node.backoffUntil.map { $0 <= now } ?? true)
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

            let isLocalFile = isAuthorizedLocalFile(url, roots: localWorkspaceRoots)
            guard isLocalFile || (try? ArchonNetworkPolicy.publicInternet.validate(url)) != nil else {
                nextNode.status = .failed
                try modelContext.save()
                continue
            }
            guard isLocalFile || !ArchonNetworkSecurity.isZeroCloudEnabled else {
                nextNode.status = .failed
                try modelContext.save()
                continue
            }
            
            if !isLocalFile {
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

                lastCrawlTimes[domain] = Date()
            }
            
            // Update crawl status and save timestamp
            nextNode.status = .crawling
            nextNode.lastAttemptedAt = Date()
            try modelContext.save()
            
            return url
        }
    }
}
