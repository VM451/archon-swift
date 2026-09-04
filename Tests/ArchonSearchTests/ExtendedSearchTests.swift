import Testing
import Foundation
@testable import ArchonSearch

@Suite("Extended Search Features & Stealth Extraction Tests")
struct ExtendedSearchTests {

    @Test("Search URL policy rejects private network targets and bounds local files")
    func searchURLBoundary() throws {
        #expect(!SearchURLPolicy.validate(URL(string: "http://127.0.0.1/admin")!))
        #expect(!SearchURLPolicy.validate(URL(string: "http://192.168.1.10/private")!))
        #expect(SearchURLPolicy.validate(URL(string: "https://example.com")!))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bounded local content".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SearchURLPolicy.validateLocalFile(file))
    }

    @Test("Monitor drops unsafe webhook targets")
    func monitorWebhookBoundary() async {
        let monitor = ArchonSearchMonitor(
            searchEngine: ArchonSearch(),
            configuration: .init(
                query: "test",
                cadence: 1,
                webhookURL: URL(string: "http://127.0.0.1:8080/callback")
            )
        )
        let configuration = await monitor.configuration
        #expect(configuration.webhookURL == nil)
    }

    @Test("StealthHeaders generates valid browser User-Agent strings and security headers")
    func testStealthHeadersGeneration() {
        let ua = StealthHeaders.randomUserAgent()
        #expect(ua.contains("Mozilla/5.0"))

        let headers = StealthHeaders.standardHeaders()
        #expect(headers["User-Agent"] != nil)
        #expect(headers["Accept-Language"] == "en-US,en;q=0.9")
        #expect(headers["Upgrade-Insecure-Requests"] == "1")
    }

    @Test("HTMLContentExtractor parses title, cleans DOM, and strips scripts/styles")
    func testHTMLContentExtraction() {
        let rawHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>  ArchonSearch Documentation  </title>
            <style>body { background: red; }</style>
            <script>console.log("malicious");</script>
        </head>
        <body>
            <h1>Welcome to ArchonSearch &amp; Apple Intelligence</h1>
            <p>On-device local search &lt;100% private&gt; &quot;zero-cloud&quot;.</p>
        </body>
        </html>
        """

        let title = HTMLContentExtractor.extractTitle(from: rawHTML)
        #expect(title == "ArchonSearch Documentation")

        let text = HTMLContentExtractor.extractText(from: rawHTML)
        #expect(!text.contains("console.log"))
        #expect(!text.contains("background: red"))
        #expect(text.contains("ArchonSearch & Apple Intelligence"))
        #expect(text.contains("<100% private> \"zero-cloud\"."))

        let highlights = HTMLContentExtractor.highlights(from: "Line 1 is very short\nLine 2 is long enough to be highlighted as important semantic context\nLine 3 also provides great detail", maxHighlights: 2)
        #expect(highlights.count == 2)
    }

    @Test("LivecrawlPolicy models support fast and full scraping configurations")
    func testLivecrawlPolicies() {
        let fastPolicy = LivecrawlPolicy.fast
        #expect(fastPolicy == .fast)

        let scrapeConfig = ScrapeConfiguration(
            actions: [.scroll(times: 2), .waitForSelector(selector: "#content", timeout: 5.0)],
            convertToMarkdown: true,
            includeSelectors: ["article"],
            excludeSelectors: ["nav"]
        )
        let fullPolicy = LivecrawlPolicy.full(scrapeConfig: scrapeConfig)
        #expect(fullPolicy == .full(scrapeConfig: scrapeConfig))
    }

    @Test("SearchResult and ContentsResult serialize and deserialize properly")
    func testResultCodables() throws {
        let searchRes = SearchResult(
            url: URL(string: "https://developer.apple.com/swift-testing")!,
            title: "Swift Testing Guide",
            snippet: "A modern testing library for Swift.",
            highlights: ["modern testing library"]
        )

        let encoded = try JSONEncoder().encode(searchRes)
        let decoded = try JSONDecoder().decode(SearchResult.self, from: encoded)
        #expect(decoded.title == "Swift Testing Guide")
        #expect(decoded.highlights.first == "modern testing library")

        let contentsRes = ContentsResult(
            url: URL(string: "https://developer.apple.com")!,
            title: "Apple Developer",
            markdown: "Develop apps for Apple platforms.",
            html: "<html><body>Develop apps for Apple platforms.</body></html>",
            highlights: ["Develop apps"]
        )
        let contentsData = try JSONEncoder().encode(contentsRes)
        let decodedContents = try JSONDecoder().decode(ContentsResult.self, from: contentsData)
        #expect(decodedContents.title == "Apple Developer")
        #expect(decodedContents.highlights.first == "Develop apps")
    }
}
