import Testing
import Foundation
@testable import ArchonSearch

@Suite("NativeReader and RetrievalRouter Tests")
struct NativeReaderAndRouterTests {
    private let testURL = URL(string: "https://example.com/test-article") ?? URL(fileURLWithPath: "/")

    @Test("SwiftSoupArticleExtractor strips noise and generates clean text and markdown")
    func testSwiftSoupArticleExtractor() throws {
        let extractor = SwiftSoupArticleExtractor()
        let html = """
        <html><head><title>SwiftSoup Guide</title>
        <meta name="author" content="Grace Hopper">
        <meta property="article:published_time" content="2026-09-08T12:00:00Z">
        </head><body>
        <nav>Navigation links Home About</nav>
        <div class="cookie-banner">Accept cookies banner</div>
        <article>
        <h1>Article Heading</h1>
        <p>This is the first paragraph describing something critical in detail.</p>
        <h2>Subheading Here</h2>
        <p>This is the second paragraph with a <a href="https://example.com/link">helpful link</a>.</p>
        <ul><li>Item one</li><li>Item two</li></ul>
        </article>
        <footer>Footer copyright 2026</footer>
        </body></html>
        """

        let result = try #require(extractor.extract(html: html, url: testURL))
        #expect(result.title == "SwiftSoup Guide")
        #expect(result.author == "Grace Hopper")
        #expect(result.headings.contains("Article Heading"))
        #expect(result.text.contains("first paragraph describing something"))
        #expect(!result.text.contains("Accept cookies"))
        #expect(!result.text.contains("Navigation links"))
        #expect(result.markdown.contains("# Article Heading"))
        #expect(result.markdown.contains("[helpful link](https://example.com/link)"))

        let article = try #require(extractor.extractArticle(from: html, url: testURL))
        #expect(article.title == "SwiftSoup Guide")
        #expect(article.method == .staticFetch)
    }

    @Test("RetrievalRouter health report checks crawler and native availability")
    func testRouterHealthReport() async {
        let router = RetrievalRouter(crawlClient: nil, nativeReader: NativeReader())
        let report = await router.healthReport()
        #expect(!report.isCrawlerAvailable)
        #expect(report.isNativeAvailable)
        #expect(report.isHealthy)
    }

    @Test("RetrievalRouter nativeOnly mode routes directly to NativeReader")
    func testRouterNativeOnlyMode() async {
        let router = RetrievalRouter(crawlClient: nil, nativeReader: NativeReader())
        let invalidURL = URL(string: "invalid://") ?? URL(fileURLWithPath: "/")
        await #expect(throws: SearchError.self) {
            try await router.read(url: invalidURL, options: ReaderOptions(mode: .nativeOnly))
        }
    }

    @Test("RetrievalRouter crawlerOnly mode fails when crawler is missing")
    func testRouterCrawlerOnlyFailsWithoutClient() async {
        let router = RetrievalRouter(crawlClient: nil, nativeReader: NativeReader())
        await #expect(throws: SearchError.self) {
            try await router.read(url: testURL, options: ReaderOptions(mode: .crawlerOnly))
        }
    }

    @Test("ReaderOptions and RetrievalHealthReport structures are Sendable and Codable")
    func testModelsCodable() throws {
        let options = ReaderOptions(mode: .preferNative, timeout: 5.0, minBodyCharacters: 300)
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ReaderOptions.self, from: data)
        #expect(decoded.mode == .preferNative)
        #expect(decoded.timeout == 5.0)
        #expect(decoded.minBodyCharacters == 300)

        let report = RetrievalHealthReport(isCrawlerAvailable: false, isNativeAvailable: true)
        let reportData = try JSONEncoder().encode(report)
        let decodedReport = try JSONDecoder().decode(RetrievalHealthReport.self, from: reportData)
        #expect(!decodedReport.isCrawlerAvailable)
        #expect(decodedReport.isNativeAvailable)
        #expect(decodedReport.isHealthy)
    }
}
