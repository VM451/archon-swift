import Testing
import Foundation
@testable import ArchonSearch

@Suite("Article Extraction Tests")
struct ArticleExtractionTests {

    private let url = URL(string: "https://example.com/article")!
    private let extractor = HeuristicArticleExtractor()

    @Test("Extractor strips chrome and keeps the article body")
    func stripsBoilerplate() throws {
        let html = """
        <html><head><title>Test Article</title></head><body>
        <nav>Home Products Pricing About Sign In</nav>
        <div class="cookie-banner">We use cookies. Accept all.</div>
        <div class="sidebar-promo">Subscribe now! Related stories here.</div>
        <article>
        <h1>Real headline</h1>
        <p>\(String(repeating: "The article body carries the meaningful reporting content here. ", count: 12))</p>
        <p>\(String(repeating: "A second paragraph continues the story with further detail. ", count: 12))</p>
        </article>
        <footer>Copyright 2026. Privacy Policy. Terms of Service.</footer>
        </body></html>
        """
        let article = try #require(extractor.extractArticle(from: html, url: url))
        #expect(article.title == "Test Article")
        #expect(article.text.contains("meaningful reporting"))
        #expect(!article.text.contains("We use cookies"))
        #expect(!article.text.contains("Copyright 2026"))
        #expect(!article.text.contains("Sign In"))
        #expect(article.headings.contains("Real headline"))
        #expect(article.method == .staticFetch)
    }

    @Test("Extractor removes scripts and styles before scoring")
    func stripsScriptsAndStyles() throws {
        let html = """
        <html><head><title>Styled</title><style>body{color:red}</style>
        <script>fetch('/ads'); document.write('promo');</script></head><body>
        <main><p>\(String(repeating: "Visible paragraph text for readers. ", count: 20))</p></main>
        </body></html>
        """
        let article = try #require(extractor.extractArticle(from: html, url: url))
        #expect(!article.text.contains("fetch('/ads')"))
        #expect(!article.text.contains("color:red"))
        #expect(article.text.contains("Visible paragraph"))
    }

    @Test("Extractor reads author and published-date metadata")
    func readsMetadata() throws {
        let html = """
        <html><head><title>Meta</title>
        <meta name="author" content="Ada Lovelace">
        <meta property="article:published_time" content="2026-09-01T10:00:00Z">
        </head><body>
        <article><p>\(String(repeating: "Dated reporting content goes here. ", count: 20))</p></article>
        </body></html>
        """
        let article = try #require(extractor.extractArticle(from: html, url: url))
        #expect(article.author == "Ada Lovelace")
        #expect(article.publishedAt != nil)
    }

    @Test("JS shell page yields thin text eligible for escalation")
    func jsShellIsThin() {
        let html = """
        <html><head><title>App</title></head><body>
        <div id="app"></div>
        <script src="main.js"></script>
        </body></html>
        """
        let article = extractor.extractArticle(from: html, url: url)
        let characters = article?.text.count ?? 0
        #expect(characters < CleanArticle.minimumBodyCharacters)
    }

    @Test("Empty body returns nil instead of an empty article")
    func emptyBodyIsNil() {
        let html = "<html><head><title>Blank</title></head><body></body></html>"
        #expect(extractor.extractArticle(from: html, url: url) == nil)
    }

    @Test("Extractor recovers text from malformed markup")
    func recoversMalformedMarkup() throws {
        let html = "<html><body><article><p>Unclosed paragraph<p>Second <b>bold oops</article>trailing"
        let article = try #require(extractor.extractArticle(from: html, url: url))
        #expect(article.text.contains("Unclosed paragraph"))
        #expect(article.text.contains("bold oops"))
    }

    @Test("Extractor drops in-article promo but keeps genuine paragraphs")
    func dropsNestedPromo() throws {
        let html = """
        <html><head><title>Nested</title></head><body><article><h1>Head</h1>
        <p>Genuine opening paragraph with real reporting content here.</p>
        <div class="promo">Sponsored: miracle pills cure everything today</div>
        <p>Genuine closing paragraph with further real reporting content.</p>
        <div id="comments"><p>User comment one here</p><p>User comment two here</p></div>
        </article></body></html>
        """
        let article = try #require(extractor.extractArticle(from: html, url: url))
        #expect(!article.text.contains("miracle pills"))
        #expect(article.text.contains("Genuine opening"))
        #expect(article.text.contains("Genuine closing"))
    }
}
