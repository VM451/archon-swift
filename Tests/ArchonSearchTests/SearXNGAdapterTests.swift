import Testing
import Foundation
@testable import ArchonSearch

private final class SearXNGMockProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("SearXNG Adapter Tests", .serialized)
struct SearXNGAdapterTests {

    @Test("SearXNGRequest constructs valid query URLs")
    func requestURLGeneration() throws {
        guard let base = URL(string: "http://localhost:8080") else { return }
        let request = SearXNGRequest(
            query: "swift strict concurrency",
            format: "json",
            categories: ["general", "it"],
            engines: ["google", "bing"],
            pageno: 2,
            timeRange: "week",
            safeSearch: 1
        )
        guard let url = request.makeURL(baseURL: base) else {
            Issue.record("URL generation failed")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        #expect(components?.path == "/search")
        let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["q"] == "swift strict concurrency")
        #expect(items["format"] == "json")
        #expect(items["pageno"] == "2")
        #expect(items["categories"] == "general,it")
        #expect(items["engines"] == "google,bing")
        #expect(items["time_range"] == "week")
        #expect(items["safesearch"] == "1")
    }

    @Test("SearXNGResponse decodes JSON and handles missing optional fields")
    func responseDecoding() throws {
        let json = """
        {
            "query": "archon",
            "number_of_results": 1,
            "results": [
                {
                    "url": "https://example.com/archon",
                    "title": "Archon Local AI",
                    "content": "On-device private agent",
                    "engine": "duckduckgo",
                    "score": 0.95
                }
            ],
            "answers": ["42"],
            "suggestions": ["archon swift"]
        }
        """.data(using: .utf8) ?? Data()

        let decoded = try JSONDecoder().decode(SearXNGResponse.self, from: json)
        #expect(decoded.query == "archon")
        #expect(decoded.numberOfResults == 1)
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].title == "Archon Local AI")
        #expect(decoded.results[0].content == "On-device private agent")
        #expect(decoded.answers == ["42"])
        #expect(decoded.suggestions == ["archon swift"])
    }

    @Test("SearXNGClient searches and maps to SearchResult")
    func clientSearchMapping() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearXNGMockProtocol.self]
        let session = URLSession(configuration: config)

        let mockJSON = """
        {
            "query": "swift",
            "number_of_results": 1,
            "results": [
                {
                    "url": "https://swift.org",
                    "title": "Swift Programming Language",
                    "content": "A powerful and intuitive programming language.",
                    "engine": "google"
                }
            ]
        }
        """.data(using: .utf8) ?? Data()

        SearXNGMockProtocol.handler = { request in
            guard let url = request.url,
                  let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            return (resp, mockJSON)
        }

        guard let endpoint = URL(string: "http://localhost:8080") else { return }
        let client = SearXNGClient(endpoint: endpoint, session: session)
        let results = try await client.search("swift")

        #expect(results.count == 1)
        #expect(results[0].title == "Swift Programming Language")
        #expect(results[0].url.absoluteString == "https://swift.org")
        #expect(results[0].snippet.contains("powerful"))
        #expect(results[0].highlights.count == 1)

        let isHealthy = await client.checkHealth()
        #expect(isHealthy)
    }
}
