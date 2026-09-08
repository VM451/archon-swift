import Testing
import Foundation
@testable import ArchonSearch

private final class DDGMockProtocol: URLProtocol, @unchecked Sendable {
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
}

private actor MockFailingEngine: SearchEngine {
    func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult] {
        throw SearchError.networkFailure(urlString: "http://failing.local", statusCode: 503)
    }
    func checkHealth() async -> Bool { false }
}

private actor MockSuccessEngine: SearchEngine {
    let results: [SearchResult]
    init(results: [SearchResult]) { self.results = results }
    func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult] { results }
    func checkHealth() async -> Bool { true }
}

@Suite("On-Device Search Engine Tests", .serialized)
struct OnDeviceSearchEngineTests {
    @Test("DuckDuckGoSearchEngine health check returns true")
    func ddgHealthCheck() async {
        let engine = DuckDuckGoSearchEngine()
        let healthy = await engine.checkHealth()
        #expect(healthy)
    }

    @Test("DuckDuckGoSearchEngine parses HTML results with redirect resolving")
    func ddgHTMLParsing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DDGMockProtocol.self]
        let session = URLSession(configuration: config)

        let mockHTML = """
        <!DOCTYPE html>
        <html>
        <body>
        <div class="result results_links results_links_deep web-result ">
            <div class="links_main links_deep result__body">
                <h2 class="result__title">
                    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocumentation&amp;rut=1">Swift Docs</a>
                </h2>
                <a class="result__snippet" href="#">Official documentation for the Swift language.</a>
            </div>
        </div>
        </body>
        </html>
        """.data(using: .utf8) ?? Data()

        DDGMockProtocol.handler = { request in
            guard let url = request.url,
                  let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]) else {
                throw URLError(.badServerResponse)
            }
            return (resp, mockHTML)
        }

        let engine = DuckDuckGoSearchEngine(session: session)
        let results = try await engine.search("swift documentation")

        #expect(results.count == 1)
        #expect(results[0].title == "Swift Docs")
        #expect(results[0].url.absoluteString == "https://swift.org/documentation")
        #expect(results[0].snippet.contains("Official documentation"))
        #expect(results[0].engine == "duckduckgo")
    }

    @Test("CompositeSearchEngine falls back when primary fails")
    func compositeFallbackOnFailure() async throws {
        guard let sampleURL = URL(string: "https://apple.com") else { return }
        let fallbackResult = SearchResult(title: "Apple", url: sampleURL, snippet: "Apple site", engine: "fallback")
        let primary = MockFailingEngine()
        let fallback = MockSuccessEngine(results: [fallbackResult])

        let composite = CompositeSearchEngine(primary: primary, fallback: fallback)
        let results = try await composite.search("apple")

        #expect(results.count == 1)
        #expect(results[0].title == "Apple")
        #expect(results[0].engine == "fallback")
    }

    @Test("CompositeSearchEngine returns primary results when healthy")
    func compositePrimarySuccess() async throws {
        guard let sampleURL = URL(string: "https://primary.example.com") else { return }
        let primaryResult = SearchResult(title: "Primary", url: sampleURL, snippet: "Primary snippet", engine: "searxng")
        let primary = MockSuccessEngine(results: [primaryResult])
        let fallback = MockFailingEngine()

        let composite = CompositeSearchEngine(primary: primary, fallback: fallback)
        let results = try await composite.search("test")

        #expect(results.count == 1)
        #expect(results[0].title == "Primary")
        #expect(results[0].engine == "searxng")
        let healthy = await composite.checkHealth()
        #expect(healthy)
    }

    @Test("CompositeSearchEngine works when primary is nil")
    func compositeNilPrimary() async throws {
        guard let sampleURL = URL(string: "https://fallback.example.com") else { return }
        let fallbackResult = SearchResult(title: "Fallback Only", url: sampleURL, snippet: "Fallback snippet", engine: "fallback")
        let fallback = MockSuccessEngine(results: [fallbackResult])

        let composite = CompositeSearchEngine(primary: nil, fallback: fallback)
        let results = try await composite.search("test")

        #expect(results.count == 1)
        #expect(results[0].title == "Fallback Only")
        let healthy = await composite.checkHealth()
        #expect(healthy)
    }
}
