import Testing
import Foundation
@testable import ArchonSearch

private final class OnDeviceMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
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
}

private actor MockEngine: SearchEngine {
    let results: [SearchResult]
    let shouldFail: Bool

    init(results: [SearchResult] = [], shouldFail: Bool = false) {
        self.results = results
        self.shouldFail = shouldFail
    }

    func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult] {
        if shouldFail { throw SearchError.networkFailure(urlString: "mock://fail", statusCode: 500) }
        return results
    }
    func checkHealth() async -> Bool { !shouldFail }
}

@Suite("On-Device Search & Verification Suite", .serialized)
struct OnDeviceSearchTests {
    @Test("DuckDuckGoSearchEngine parses HTML SERP fixtures with uddg redirection")
    func testDuckDuckGoHTMLParsing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OnDeviceMockProtocol.self]
        let session = URLSession(configuration: config)

        let fixture = """
        <!DOCTYPE html>
        <html>
        <body>
        <div class="result results_links results_links_deep web-result ">
            <div class="links_main links_deep result__body">
                <h2 class="result__title">
                    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fswift%2F&amp;rut=1">Swift - Apple Developer</a>
                </h2>
                <a class="result__snippet" href="#">Swift is a powerful and intuitive language.</a>
            </div>
        </div>
        </body>
        </html>
        """.data(using: .utf8) ?? Data()

        OnDeviceMockProtocol.responseHandler = { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]) else {
                throw URLError(.badServerResponse)
            }
            return (response, fixture)
        }

        let engine = DuckDuckGoSearchEngine(session: session)
        let results = try await engine.search("swift")
        #expect(results.count == 1)
        #expect(results[0].title == "Swift - Apple Developer")
        #expect(results[0].url.absoluteString == "https://developer.apple.com/swift/")
        #expect(results[0].snippet.contains("powerful and intuitive"))
        #expect(results[0].engine == "duckduckgo")
    }

    @Test("CompositeSearchEngine falls back when primary fails")
    func testCompositeSearchEngineFallback() async throws {
        let url = try #require(URL(string: "https://swift.org"))
        let fallbackResult = SearchResult(title: "Swift.org", url: url, snippet: "Open source Swift", engine: "ddg")
        let primary = MockEngine(shouldFail: true)
        let fallback = MockEngine(results: [fallbackResult])

        let composite = CompositeSearchEngine(primary: primary, fallback: fallback)
        let results = try await composite.search("swift")
        #expect(results.count == 1)
        #expect(results[0].title == "Swift.org")
        #expect(results[0].engine == "ddg")
    }

    @Test("ArchonSearchClient initializes with .onDevice() and avoids localhost dependencies")
    func testArchonSearchClientOnDeviceDefaults() async throws {
        let client = ArchonSearchClient()
        let config = await client.configuration

        #expect(config.routingMode == .nativeOnly)
        #expect(config.searchEngine.searxngURL == nil)
        #expect(config.crawler.crawl4aiURL == nil)
        #expect(config == .onDevice())
    }

    @Test("WebSearchTool and ResearchTool support on-device initialization and execution")
    func testToolsOnDeviceExecution() async throws {
        let sampleURL = try #require(URL(string: "https://example.com/swift"))
        let mockResult = SearchResult(title: "Swift Guide", url: sampleURL, snippet: "A complete guide to Swift.", engine: "mock")
        let engine = MockEngine(results: [mockResult])

        let webTool = WebSearchTool(client: engine)
        let webOutput = try await webTool.execute(query: "swift")
        #expect(webOutput.contains("[1] Swift Guide"))
        #expect(webOutput.contains("https://example.com/swift"))

        let defaultWebTool = WebSearchTool()
        #expect(defaultWebTool.client is DuckDuckGoSearchEngine)

        let researchTool = ResearchTool(searchEngine: engine)
        let report = try await researchTool.execute(topic: "swift")
        #expect(report.contains("# Research Report: swift"))

        let defaultResearchTool = ResearchTool()
        #expect(defaultResearchTool.name == "deep_research")
    }
}
