import Testing
import Foundation
import SwiftData
@testable import ArchonSearch

@Suite("Crawl Schedule Tests")
struct CrawlScheduleTests {
    private func makeActor() throws -> FrontierQueueActor {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return FrontierQueueActor(modelContainer: container)
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("Dequeue round-robins across ready hosts")
    func roundRobin() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(baseDelay: 0))
        try await actor.enqueue(urls: [
            try url("https://a-rr.test/1"), try url("https://a-rr.test/2"),
            try url("https://b-rr.test/1"), try url("https://b-rr.test/2"),
        ])
        let first = try await actor.dequeueNext()
        let second = try await actor.dequeueNext()
        let third = try await actor.dequeueNext()
        let fourth = try await actor.dequeueNext()
        #expect(first?.absoluteString == "https://a-rr.test/1")
        #expect(second?.absoluteString == "https://b-rr.test/1")
        #expect(third?.absoluteString == "https://a-rr.test/2")
        #expect(fourth?.absoluteString == "https://b-rr.test/2")
        #expect(try await actor.dequeueNext() == nil)
    }

    @Test("Depth penalty orders same-host nodes with equal priority")
    func depthOrdering() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(baseDelay: 0, depthPenalty: 0.5))
        try await actor.enqueue(
            urls: [try url("https://h-depth.test/deep")],
            priorities: [5], depth: 2
        )
        try await actor.enqueue(
            urls: [try url("https://h-depth.test/shallow")],
            priorities: [5], depth: 0
        )
        #expect(try await actor.dequeueNext()?.absoluteString == "https://h-depth.test/shallow")
        #expect(try await actor.dequeueNext()?.absoluteString == "https://h-depth.test/deep")
    }

    @Test("Priorities shorter than URLs default the remainder to zero")
    func priorityDefaults() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions())
        try await actor.enqueue(
            urls: [try url("https://p-def.test/a"), try url("https://p-def.test/b")],
            priorities: [9]
        )
        let nodes = try await actor.fetchAllNodes()
        let byURL = Dictionary(uniqueKeysWithValues: nodes.map { ($0.urlString, $0.priority) })
        #expect(byURL["https://p-def.test/a"] == 9)
        #expect(byURL["https://p-def.test/b"] == 0)
    }

    @Test("Robots-delay host is skipped, not slept")
    func robotsDelaySkipped() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(baseDelay: 0))
        try await actor.enqueue(urls: [
            try url("https://delay.test/a"), try url("https://delay.test/b"),
            try url("https://zzz-skip.test/x"),
        ])
        #expect(try await actor.dequeueNext()?.absoluteString == "https://delay.test/a")
        let start = Date()
        let second = try await actor.dequeueNext()
        #expect(second?.absoluteString == "https://zzz-skip.test/x")
        #expect(Date().timeIntervalSince(start) < 1.5)
        let skipStart = Date()
        #expect(try await actor.dequeueNext() == nil)
        #expect(Date().timeIntervalSince(skipStart) < 1.5)
    }

    @Test("429 with Retry-After backs off and clamps to the cap")
    func rateLimitedBackoff() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(baseDelay: 0))
        try await actor.enqueue(urls: [
            try url("https://r429.test/page"), try url("https://ok429.test/page"),
        ])
        try await actor.reportHostOutcome(host: "r429.test", outcome: .rateLimited(retryAfter: 60))
        let nodes = try await actor.fetchAllNodes()
        let backed = try #require(nodes.first { $0.urlString == "https://r429.test/page" })
        let delta = try #require(backed.backoffUntil).timeIntervalSinceNow
        #expect(delta > 55 && delta <= 61)
        #expect(backed.status == CrawlStatus.pending.rawValue)
        #expect(try await actor.dequeueNext()?.absoluteString == "https://ok429.test/page")
        #expect(try await actor.dequeueNext() == nil)

        try await actor.reportHostOutcome(host: "c429.test", outcome: .rateLimited(retryAfter: 9999))
        try await actor.enqueue(urls: [try url("https://c429.test/page")])
        try await actor.reportHostOutcome(host: "c429.test", outcome: .rateLimited(retryAfter: 9999))
        let capped = try #require(
            (try await actor.fetchAllNodes()).first { $0.urlString == "https://c429.test/page" }
        )
        let cappedDelta = try #require(capped.backoffUntil).timeIntervalSinceNow
        #expect(cappedDelta <= 301)
    }

    @Test("Server errors back off exponentially up to maxDelay")
    func exponentialBackoff() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(
            maxRetries: 5, baseDelay: 10, maxDelay: 15
        ))
        try await actor.enqueue(urls: [try url("https://e5xx.test/page")])
        try await actor.reportHostOutcome(host: "e5xx.test", outcome: .serverError)
        let first = try #require(
            (try await actor.fetchAllNodes()).first { $0.urlString == "https://e5xx.test/page" }
        )
        let firstDelta = try #require(first.backoffUntil).timeIntervalSinceNow
        #expect(firstDelta > 8 && firstDelta <= 11)
        try await actor.reportHostOutcome(host: "e5xx.test", outcome: .serverError)
        let second = try #require(
            (try await actor.fetchAllNodes()).first { $0.urlString == "https://e5xx.test/page" }
        )
        let secondDelta = try #require(second.backoffUntil).timeIntervalSinceNow
        #expect(secondDelta > 13 && secondDelta <= 16)
    }

    @Test("Success clears backoff and failure counts")
    func successClears() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(maxRetries: 5, baseDelay: 30))
        try await actor.enqueue(urls: [try url("https://ok-clear.test/page")])
        try await actor.reportHostOutcome(host: "ok-clear.test", outcome: .serverError)
        #expect(try await actor.dequeueNext() == nil)
        try await actor.reportHostOutcome(host: "ok-clear.test", outcome: .success)
        let node = try #require((try await actor.fetchAllNodes()).first)
        #expect(node.backoffUntil == nil)
        #expect(node.failureCount == 0)
        #expect(try await actor.dequeueNext()?.absoluteString == "https://ok-clear.test/page")
    }

    @Test("Retry count at maxRetries marks nodes failed")
    func maxRetriesFailed() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(maxRetries: 2, baseDelay: 0))
        try await actor.enqueue(urls: [try url("https://m-retry.test/page")])
        try await actor.reportHostOutcome(host: "m-retry.test", outcome: .serverError)
        var node = try #require((try await actor.fetchAllNodes()).first)
        #expect(node.status == CrawlStatus.pending.rawValue)
        try await actor.reportHostOutcome(host: "m-retry.test", outcome: .serverError)
        node = try #require((try await actor.fetchAllNodes()).first)
        #expect(node.status == CrawlStatus.failed.rawValue)
        #expect(try await actor.dequeueNext() == nil)

        try await actor.enqueue(urls: [try url("https://m-retry.test/other")])
        try await actor.markFailed(urlString: "https://m-retry.test/other")
        try await actor.markFailed(urlString: "https://m-retry.test/other")
        let other = try #require(
            (try await actor.fetchAllNodes()).first { $0.urlString == "https://m-retry.test/other" }
        )
        #expect(other.status == CrawlStatus.failed.rawValue)
    }

    @Test("Per-host queue bound drops lowest priority deterministically")
    func perHostBound() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(maxQueuedPerHost: 2))
        try await actor.enqueue(
            urls: [
                try url("https://bound.test/low"),
                try url("https://bound.test/high"),
                try url("https://bound.test/mid"),
            ],
            priorities: [1, 5, 3]
        )
        let kept = try await actor.fetchAllNodes()
        #expect(kept.count == 2)
        #expect(Set(kept.map(\.priority)) == [5, 3])
    }

    @Test("In-flight host cap withholds new hosts")
    func hostsInFlightCap() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(maxHostsInFlight: 1, baseDelay: 0))
        try await actor.enqueue(urls: [
            try url("https://a-flight.test/1"), try url("https://b-flight.test/1"),
        ])
        #expect(try await actor.dequeueNext()?.absoluteString == "https://a-flight.test/1")
        #expect(try await actor.dequeueNext() == nil)
        try await actor.markCompleted(urlString: "https://a-flight.test/1")
        #expect(try await actor.dequeueNext()?.absoluteString == "https://b-flight.test/1")
    }

    @Test("Cancellation during dequeue leaves a recoverable pending node")
    func cancellationRecoverable() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        await actor.configureScheduling(CrawlScheduleOptions(baseDelay: 0))
        try await actor.enqueue(urls: [try url("https://cancel.test/page")])
        await withTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                do {
                    _ = try await actor.dequeueNext()
                    Issue.record("Expected CancellationError")
                } catch is CancellationError {
                } catch {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
        let nodes = try await actor.fetchAllNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.status == CrawlStatus.pending.rawValue)
        #expect(try await actor.dequeueNext()?.absoluteString == "https://cancel.test/page")
    }

    @Test("Effective score combines priority, depth, and failures")
    func effectiveScoreMath() {
        let node = CrawlNode(
            urlString: "https://s.test/x", priority: 10,
            domain: "s.test", depth: 2, failureCount: 3
        )
        let options = CrawlScheduleOptions(depthPenalty: 0.5, failurePenalty: 1.0)
        #expect(FrontierQueueActor.effectiveScore(node, options: options) == 6.0)
    }
}
