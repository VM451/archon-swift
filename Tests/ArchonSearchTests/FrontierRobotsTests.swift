import Testing
import Foundation
import SwiftData
@testable import ArchonSearch

/// Host-keyed robots.txt fixture server. Fixtures are selected by request
/// host so parallel suites can share one fixed handler without races:
/// deny.test disallows /private, delay.test sets Crawl-delay 2, every other
/// host answers 404 (allow-all, the robots convention for a missing file).
final class RobotsMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func hostKeyedHandler(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url, let host = url.host?.lowercased() else {
            throw URLError(.badURL)
        }
        if host == "fail.test" {
            throw URLError(.timedOut)
        }
        let status: Int
        let body: String
        switch host {
        case "deny.test":
            status = 200
            body = "User-agent: *\nDisallow: /private\n"
        case "delay.test":
            status = 200
            body = "User-agent: *\nCrawl-delay: 2\n"
        case "error.test":
            status = 500
            body = ""
        default:
            status = 404
            body = ""
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(body.utf8))
    }
}

func makeRobotsMockSession() -> URLSession {
    RobotsMockProtocol.handler = RobotsMockProtocol.hostKeyedHandler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RobotsMockProtocol.self]
    return URLSession(configuration: config)
}

@Suite("Frontier Robots Tests")
struct FrontierRobotsTests {
    private func makeActor() throws -> FrontierQueueActor {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return FrontierQueueActor(modelContainer: container)
    }

    @Test("Crawl-delay parsing clamps huge values and rejects invalid ones")
    func testCrawlDelayClamp() async {
        let parser = RobotsParser()
        let huge = await parser.parse("User-agent: *\nCrawl-delay: 9999", forUserAgent: "*")
        #expect(huge.crawlDelay == 300)
        let negative = await parser.parse("User-agent: *\nCrawl-delay: -5", forUserAgent: "*")
        #expect(negative.crawlDelay == nil)
        let garbage = await parser.parse("User-agent: *\nCrawl-delay: soon", forUserAgent: "*")
        #expect(garbage.crawlDelay == nil)
    }

    @Test("canCrawl fails closed on fetch errors and server failures")
    func testCanCrawlFailClosed() async throws {
        let session = makeRobotsMockSession()
        let parser = RobotsParser(session: session)
        let timeoutPage = try #require(URL(string: "https://fail.test/page"))
        let errorPage = try #require(URL(string: "https://error.test/page"))
        let missingPage = try #require(URL(string: "https://allow.test/page"))
        #expect(await parser.canCrawl(timeoutPage) == false)
        #expect(await parser.canCrawl(errorPage) == false)
        #expect(await parser.canCrawl(missingPage) == true)
    }

    @Test("Frontier skips robots-denied URLs and marks them failed")
    func testFrontierSkipsDeniedURLs() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())

        let denied = try #require(URL(string: "https://deny.test/private/secret"))
        let allowed = try #require(URL(string: "https://deny.test/public/page"))
        try await actor.enqueue(urls: [denied, allowed])

        let first = try await actor.dequeueNext()
        #expect(first == allowed)

        let nodes = try await actor.fetchAllNodes()
        let deniedNode = try #require(nodes.first { $0.urlString == denied.absoluteString })
        #expect(deniedNode.status == CrawlStatus.failed.rawValue)
    }

    @Test("Frontier honors the robots crawl-delay between same-domain dequeues")
    func testFrontierHonorsCrawlDelay() async throws {
        let actor = try makeActor()
        await actor.setRobotsSession(makeRobotsMockSession())
        let firstURL = try #require(URL(string: "https://delay.test/a"))
        let secondURL = try #require(URL(string: "https://delay.test/b"))
        try await actor.enqueue(urls: [firstURL, secondURL])

        _ = try await actor.dequeueNext()
        let start = Date()
        _ = try await actor.dequeueNext()
        // Lower bound only: the enforced delay must elapse. No upper bound —
        // loaded CI machines must never fail a politeness proof.
        #expect(Date().timeIntervalSince(start) >= 1.9)
    }
}
