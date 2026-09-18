import Foundation
import SwiftData
import ArchonCore

@ModelActor
public actor FrontierQueueActor {
    private var robotsParser = RobotsParser()
    private var lastCrawlTimes = [String: Date]()
    private let defaultPolitenessDelay: TimeInterval = 1.0

    /// Installed scheduling options. `nil` keeps legacy behavior (global
    /// priority order, sleeping politeness waits); non-`nil` enables
    /// politeness-aware round-robin scheduling that skips unready hosts
    /// instead of sleeping.
    var scheduleOptions: CrawlScheduleOptions?
    private var hostBackoffUntil = [String: Date]()
    private var servedHostsRound = Set<String>()

    /// Replaces the robots.txt fetch session (robots cache resets). Hosts use
    /// this to share session configuration; tests use it to inject fixtures.
    public func setRobotsSession(_ session: URLSession?) {
        robotsParser = RobotsParser(session: session)
    }

    /// Installs politeness-aware scheduling (SEARCH-004): depth/failure
    /// weighted priority, per-host round-robin, bounded backoff, and
    /// per-host queue bounds. Dequeue stops sleeping for politeness and
    /// instead skips unready hosts.
    public func configureScheduling(_ options: CrawlScheduleOptions) {
        scheduleOptions = options
    }

    /// Enqueues new URLs to crawl if they haven't been crawled or queued yet.
    public func enqueue(
        urls: [URL],
        priority: Int = 0,
        parentURLString: String? = nil,
        localWorkspaceRoots: [URL] = []
    ) throws {
        var affectedHosts = Set<String>()
        for url in urls {
            if try insertNode(
                url: url, priority: priority,
                parentURLString: parentURLString, depth: 0,
                localWorkspaceRoots: localWorkspaceRoots
            ) {
                affectedHosts.insert(url.host?.lowercased() ?? "")
            }
        }
        try modelContext.save()
        try enforcePerHostBounds(hosts: affectedHosts)
    }

    /// Depth-aware enqueue with per-URL priorities. URLs beyond
    /// `priorities.count` receive priority 0. `depth` seeds the nodes'
    /// depth penalty. Per-host queue bounds apply when scheduling is
    /// configured.
    public func enqueue(
        urls: [URL],
        priorities: [Int],
        parentURLString: String? = nil,
        depth: Int = 0,
        localWorkspaceRoots: [URL] = []
    ) throws {
        var affectedHosts = Set<String>()
        for (index, url) in urls.enumerated() {
            let priority = index < priorities.count ? priorities[index] : 0
            if try insertNode(
                url: url, priority: priority,
                parentURLString: parentURLString, depth: max(0, depth),
                localWorkspaceRoots: localWorkspaceRoots
            ) {
                affectedHosts.insert(url.host?.lowercased() ?? "")
            }
        }
        try modelContext.save()
        try enforcePerHostBounds(hosts: affectedHosts)
    }

    /// Records a host fetch outcome: clears backoff on success, applies
    /// bounded backoff on 429/5xx, and fails nodes at `maxRetries`.
    public func reportHostOutcome(host: String, outcome: CrawlHostOutcome) throws {
        let options = scheduleOptions ?? CrawlScheduleOptions()
        let normalized = host.lowercased()
        let hostKey = normalized
        let now = Date()
        let fetch = FetchDescriptor<CrawlNode>(
            predicate: #Predicate<CrawlNode> { $0.domain == hostKey }
        )
        let hostNodes = try modelContext.fetch(fetch).filter {
            $0.status == .pending || $0.status == .crawling
        }
        switch outcome {
        case .success:
            hostBackoffUntil[normalized] = nil
            for node in hostNodes {
                node.failureCount = 0
                node.backoffUntil = nil
            }
        case .rateLimited(let retryAfter):
            for node in hostNodes { node.failureCount += 1 }
            let worst = hostNodes.map(\.failureCount).max() ?? 1
            let delay = retryAfter.map { options.clampedDelay($0) }
                ?? options.exponentialDelay(failures: worst)
            hostBackoffUntil[normalized] = now.addingTimeInterval(delay)
            for node in hostNodes {
                applyFailure(to: node, delay: delay, options: options, now: now)
            }
        case .serverError:
            for node in hostNodes { node.failureCount += 1 }
            let worst = hostNodes.map(\.failureCount).max() ?? 1
            hostBackoffUntil[normalized] = now.addingTimeInterval(
                options.exponentialDelay(failures: worst)
            )
            for node in hostNodes {
                applyFailure(
                    to: node,
                    delay: options.exponentialDelay(failures: node.failureCount),
                    options: options, now: now
                )
            }
        }
        try modelContext.save()
    }

    private func applyFailure(to node: CrawlNode, delay: TimeInterval, options: CrawlScheduleOptions, now: Date) {
        node.retryCount += 1
        if node.retryCount >= options.clampedMaxRetries {
            node.status = .failed
            node.backoffUntil = nil
        } else {
            node.status = .pending
            node.backoffUntil = now.addingTimeInterval(delay)
        }
    }

    /// Inserts one node unless already queued or scraped. Returns whether a
    /// node was inserted.
    private func insertNode(
        url: URL,
        priority: Int,
        parentURLString: String?,
        depth: Int,
        localWorkspaceRoots: [URL]
    ) throws -> Bool {
        guard isPermitted(url, localWorkspaceRoots: localWorkspaceRoots) else {
            return false
        }
        let urlString = url.absoluteString
        let domain = url.host?.lowercased() ?? ""

        let nodeFetch = FetchDescriptor<CrawlNode>(
            predicate: #Predicate<CrawlNode> { $0.urlString == urlString }
        )
        let existingNodes = try modelContext.fetch(nodeFetch)

        let pageFetch = FetchDescriptor<ScrapedPage>(
            predicate: #Predicate<ScrapedPage> { $0.urlString == urlString }
        )
        let existingPages = try modelContext.fetch(pageFetch)

        if existingNodes.isEmpty && existingPages.isEmpty {
            let newNode = CrawlNode(
                urlString: urlString, status: .pending,
                priority: priority, domain: domain,
                parentURLString: parentURLString, depth: depth
            )
            modelContext.insert(newNode)
            return true
        }
        return false
    }

    /// Drops lowest-priority pending nodes beyond `maxQueuedPerHost`, keeping
    /// highest priority (ties: earliest added, then lowest URL). No-op until
    /// scheduling is configured.
    private func enforcePerHostBounds(hosts: Set<String>) throws {
        guard let options = scheduleOptions else { return }
        let maxKept = options.clampedMaxQueuedPerHost
        for host in hosts {
            let hostKey = host
            let fetch = FetchDescriptor<CrawlNode>(
                predicate: #Predicate<CrawlNode> { $0.domain == hostKey }
            )
            let pending = try modelContext.fetch(fetch).filter { $0.status == .pending }
            guard pending.count > maxKept else { continue }
            let ordered = pending.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
                return $0.urlString < $1.urlString
            }
            for victim in ordered.dropFirst(maxKept) {
                modelContext.delete(victim)
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
                backoffUntil: node.backoffUntil,
                depth: node.depth,
                failureCount: node.failureCount,
                retryCount: node.retryCount
            )
        }
    }

    /// Dequeues the next crawlable URL, respecting robots.txt and domain rate limits.
    ///
    /// Cancellation-checked: throwing `CancellationError` leaves nodes in
    /// their pre-call state (nodes are only marked `crawling` at the end).
    public func dequeueNext(localWorkspaceRoots: [URL] = []) async throws -> URL? {
        try Task.checkCancellation()
        if scheduleOptions != nil {
            return try await dequeueScheduled(localWorkspaceRoots: localWorkspaceRoots)
        }
        return try await dequeueLegacy(localWorkspaceRoots: localWorkspaceRoots)
    }

    /// Scheduled dequeue: effective-score order within each host
    /// (`priority - depth x depthPenalty - failures x failurePenalty`),
    /// round-robin across ready hosts, skipping hosts in backoff or
    /// robots-delay without sleeping. Returns the next ready host's URL,
    /// or `nil` when nothing is servable right now.
    private func dequeueScheduled(localWorkspaceRoots: [URL]) async throws -> URL? {
        guard let options = scheduleOptions else { return nil }
        let now = Date()
        var descriptor = FetchDescriptor<CrawlNode>()
        descriptor.fetchLimit = 2000
        let nodes = try modelContext.fetch(descriptor)

        var inFlightHosts = Set(nodes.filter { $0.status == .crawling }.map(\.domain))

        var pendingByHost: [String: [CrawlNode]] = [:]
        for node in nodes where node.status == .pending {
            try Task.checkCancellation()
            if let until = node.backoffUntil, until > now { continue }
            if let hostUntil = hostBackoffUntil[node.domain], hostUntil > now { continue }
            pendingByHost[node.domain, default: []].append(node)
        }
        guard !pendingByHost.isEmpty else { return nil }

        let readyHosts = Set(pendingByHost.keys)
        if readyHosts.isSubset(of: servedHostsRound) {
            servedHostsRound.removeAll()
        }
        let orderedHosts = readyHosts.sorted {
            let unserved0 = !servedHostsRound.contains($0)
            let unserved1 = !servedHostsRound.contains($1)
            if unserved0 != unserved1 { return unserved0 }
            return $0 < $1
        }

        for host in orderedHosts {
            try Task.checkCancellation()
            if !inFlightHosts.contains(host),
               inFlightHosts.count >= options.clampedMaxHostsInFlight {
                continue
            }
            let ordered = (pendingByHost[host] ?? []).sorted {
                let score0 = Self.effectiveScore($0, options: options)
                let score1 = Self.effectiveScore($1, options: options)
                if score0 != score1 { return score0 > score1 }
                if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
                return $0.urlString < $1.urlString
            }
            var hostSkipped = false
            for node in ordered {
                try Task.checkCancellation()
                guard let url = URL(string: node.urlString) else {
                    modelContext.delete(node)
                    try modelContext.save()
                    continue
                }

                let isLocalFile = isAuthorizedLocalFile(url, roots: localWorkspaceRoots)
                guard isLocalFile || (try? ArchonNetworkPolicy.publicInternet.validate(url)) != nil else {
                    node.status = .failed
                    try modelContext.save()
                    continue
                }
                guard isLocalFile || !ArchonNetworkSecurity.isZeroCloudEnabled else {
                    node.status = .failed
                    try modelContext.save()
                    continue
                }

                if !isLocalFile {
                    let isAllowed = await robotsParser.canCrawl(url)
                    try Task.checkCancellation()
                    if !isAllowed {
                        node.status = .failed
                        try modelContext.save()
                        continue
                    }

                    let robotsDelay = await robotsParser.crawlDelay(for: url)
                    try Task.checkCancellation()
                    let delay = min(
                        options.clampedDelay(robotsDelay ?? options.clampedBaseDelay),
                        options.clampedMaxDelay
                    )
                    if let lastCrawl = lastCrawlTimes[host] {
                        let elapsed = Date().timeIntervalSince(lastCrawl)
                        if elapsed < delay {
                            hostSkipped = true
                            break
                        }
                    }
                    lastCrawlTimes[host] = Date()
                }

                node.status = .crawling
                node.lastAttemptedAt = Date()
                try modelContext.save()
                servedHostsRound.insert(host)
                inFlightHosts.insert(host)
                return url
            }
            if hostSkipped { continue }
        }
        return nil
    }

    nonisolated static func effectiveScore(_ node: CrawlNode, options: CrawlScheduleOptions) -> Double {
        Double(node.priority)
            - Double(max(0, node.depth)) * options.clampedDepthPenalty
            - Double(max(0, node.failureCount)) * options.clampedFailurePenalty
    }

    /// Legacy dequeue: global priority order with sleeping politeness waits.
    private func dequeueLegacy(localWorkspaceRoots: [URL]) async throws -> URL? {
        while true {
            try Task.checkCancellation()
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
