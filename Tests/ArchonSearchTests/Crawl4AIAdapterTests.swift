import Testing
import Foundation
@testable import ArchonSearch

private final class Crawl4AIMockProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("Crawl4AI Adapter Tests", .serialized)
struct Crawl4AIAdapterTests {

    @Test("Crawl4AIRequest encodes options to expected JSON format")
    func requestEncoding() throws {
        guard let targetURL = URL(string: "https://apple.com/swift") else { return }
        let options = CrawlOptions(
            priority: 8,
            wordCountThreshold: 200,
            cssSelector: "article.main",
            magic: true,
            simulateUser: true,
            extractionStrategy: "llm"
        )
        let request = Crawl4AIRequest(url: targetURL, options: options)
        let encoded = try JSONEncoder().encode(request)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(jsonObject?["urls"] as? [String] == ["https://apple.com/swift"])
        #expect(jsonObject?["priority"] as? Int == 8)
        #expect(jsonObject?["word_count_threshold"] as? Int == 200)
        #expect(jsonObject?["css_selector"] as? String == "article.main")
        #expect(jsonObject?["magic"] as? Bool == true)
        #expect(jsonObject?["simulate_user"] as? Bool == true)
        #expect(jsonObject?["extraction_strategy"] as? String == "llm")
    }

    @Test("Crawl4AIClient crawls and returns WebDocument")
    func clientCrawlSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Crawl4AIMockProtocol.self]
        let session = URLSession(configuration: config)

        let mockResponseJSON = """
        {
            "url": "https://example.com/article",
            "success": true,
            "status_code": 200,
            "html": "<html><body><h1>Title</h1><p>Full content</p></body></html>",
            "fit_html": "<h1>Title</h1><p>Full content</p>",
            "markdown": {
                "raw_markdown": "# Title\\n\\nFull content",
                "fit_markdown": "# Title\\n\\nTrimmed fit content"
            },
            "metadata": {
                "title": "Article Title",
                "author": "Archon"
            }
        }
        """.data(using: .utf8) ?? Data()

        Crawl4AIMockProtocol.handler = { request in
            guard let url = request.url,
                  let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            return (resp, mockResponseJSON)
        }

        guard let endpoint = URL(string: "http://localhost:11235"),
              let targetURL = URL(string: "https://example.com/article") else { return }
        let client = Crawl4AIClient(endpoint: endpoint, apiToken: "test-token", session: session)
        let doc = try await client.crawl(url: targetURL)

        #expect(doc.url.absoluteString == "https://example.com/article")
        #expect(doc.title == "Article Title")
        #expect(doc.markdown.contains("Trimmed fit content"))
        #expect(doc.text.contains("Full content"))
        #expect(doc.metadata["author"] == "Archon")

        let isHealthy = await client.checkHealth()
        #expect(isHealthy)
    }

    @Test("Crawl4AIClient throws extraction error when crawl fails")
    func clientCrawlFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Crawl4AIMockProtocol.self]
        let session = URLSession(configuration: config)

        let mockFailureJSON = """
        {
            "url": "https://example.com/blocked",
            "success": false,
            "status_code": 403,
            "error_message": "Cloudflare challenge presented"
        }
        """.data(using: .utf8) ?? Data()

        Crawl4AIMockProtocol.handler = { request in
            guard let url = request.url,
                  let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            return (resp, mockFailureJSON)
        }

        guard let endpoint = URL(string: "http://localhost:11235"),
              let targetURL = URL(string: "https://example.com/blocked") else { return }
        let client = Crawl4AIClient(endpoint: endpoint, session: session)

        await #expect(throws: SearchError.self) {
            try await client.crawl(url: targetURL)
        }
    }
}
