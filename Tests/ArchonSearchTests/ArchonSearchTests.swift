import Testing
import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import ArchonSearch

@Suite("Discovery Engine Tests")
struct DiscoveryEngineTests {
    @Test("Organic Link Extraction & Normalization")
    func linkParsing() async throws {
        let engine = DiscoveryEngine()
        let mockHTML = """
        <html>
        <body>
        <div class="result">
            <a class="result__url" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fpath%3Futm_source%3Dtest%26gclid%3D123&rut=123">Result 1</a>
        </div>
        <div class="result">
            <a class="result__url" href="https://other.com/page?utm_medium=email&fbclid=abc">Result 2</a>
        </div>
        <div class="result">
            <a class="result__url" href="https://duckduckgo.com/about">Internal</a>
        </div>
        </body>
        </html>
        """
        let urls = engine.parseSERP(mockHTML)
        #expect(urls.count == 2)
        #expect(urls[0].absoluteString == "https://example.com/path")
        #expect(urls[1].absoluteString == "https://other.com/page")
    }
}

@Suite("Robots Parser Tests")
struct RobotsParserTests {
    @Test("Robots.txt Rule Parsing")
    func robotsParsing() async throws {
        let parser = RobotsParser()
        let rulesContent = """
        User-agent: *
        Disallow: /private/
        Disallow: /admin
        Crawl-delay: 5.5

        User-agent: OtherBot
        Disallow: /
        """
        
        let rules = await parser.parse(rulesContent, forUserAgent: "*")
        #expect(rules.disallowPaths.count == 2)
        #expect(rules.disallowPaths.contains("/private/"))
        #expect(rules.disallowPaths.contains("/admin"))
        #expect(rules.crawlDelay == 5.5)
    }
}

@Suite("MinHash Deduplicator Tests")
struct MinHashDeduplicatorTests {
    @Test("Near Duplicate Similarity Detection")
    func jaccardSimilarity() async throws {
        let doc1 = """
        ArchonSearch is a lightweight Swift library designed for modern iOS and macOS applications.
        It provides zero-cost, 100% on-device web scraping, crawling, and structured data extraction.
        By utilizing the native Apple Intelligence framework and WKWebView, it maintains user privacy.
        Developers can integrate it easily without any external API keys or third-party dependencies.
        """
        let doc2 = """
        ArchonSearch is a lightweight Swift library designed for modern macOS and iOS applications.
        It provides zero-cost, 100% on-device web scraping, crawling, and structured data extraction.
        By utilizing the native Apple Intelligence framework and WKWebView, it maintains user privacy.
        Developers can integrate it easily without any external API keys or third-party dependencies.
        """
        let doc3 = """
        The Golden Gate Bridge is a suspension bridge spanning the Golden Gate, the one-mile-wide strait connecting San Francisco Bay and the Pacific Ocean.
        The structure links the U.S. city of San Francisco, California—the northern tip of the San Francisco Peninsula—to Marin County, carrying both U.S. Route 101 and California State Route 1 across the strait.
        It is one of the most internationally recognized symbols of San Francisco and California.
        """
        
        let sig1 = MinHashDeduplicator.generateSignature(from: doc1)
        let sig2 = MinHashDeduplicator.generateSignature(from: doc2)
        let sig3 = MinHashDeduplicator.generateSignature(from: doc3)
        
        let sim12 = MinHashDeduplicator.jaccardSimilarity(sig1: sig1, sig2: sig2)
        let sim13 = MinHashDeduplicator.jaccardSimilarity(sig1: sig1, sig2: sig3)
        
        #expect(sim12 > 0.75)
        #expect(sim13 < 0.2)
    }
}

struct TestResearch: ArchonGenerable, Codable, Sendable {
    var coreProduct: String
    var pricing: String
    var mission: String
}

@Suite("Semantic Core Tests")
struct SemanticCoreTests {
    @Test("Context Extraction and Vector Similarity")
    func vectorRanking() async throws {
        let core = ArchonSemanticCore()
        let sourceText = """
        Apple Intelligence delivers personalized experiences.
        The capital of France is Paris, which is known for art and fashion.
        SwiftData manages data storage in native Swift apps.
        """
        
        let parisContext = try await core.extractRelevantContext(from: sourceText, query: "Where is Paris?", maxCharacters: 100)
        #expect(parisContext.contains("Paris"))
        #expect(!parisContext.contains("SwiftData"))
        
        let swiftDataContext = try await core.extractRelevantContext(from: sourceText, query: "database storage in Swift", maxCharacters: 100)
        #expect(swiftDataContext.contains("SwiftData"))
        #expect(!swiftDataContext.contains("Paris"))
    }
    
    @Test("Structured extraction uses an explicitly injected model handler")
    func guidedExtractionFallback() async throws {
        let core = ArchonSemanticCore { _, _, _ in
            Data(#"{"coreProduct":"Headless CMS Platform","pricing":"$49/mo","mission":"Injected test result"}"#.utf8)
        }
        let htmlContent = "Headless CMS Platform starting at $49/mo to build a highly robust developer experience."
        
        let extracted = try await core.extract(from: htmlContent, query: "Top headless CMS startups 2026", as: TestResearch.self)
        #expect(extracted.coreProduct.localizedCaseInsensitiveContains("Headless"))
        #expect(extracted.pricing.contains("$49"))
    }
}

@Suite("Frontier Queue Actor Tests")
struct FrontierQueueActorTests {
    @Test("Frontier Scheduler CRUD Operations")
    func queueOperations() async throws {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let actor = FrontierQueueActor(modelContainer: container)
        
        let url1 = URL(string: "https://example.com/page1")!
        let url2 = URL(string: "https://example.com/page2")!
        
        try await actor.enqueue(urls: [url1, url2], priority: 5)
        
        // Dequeue first
        let first = try await actor.dequeueNext()
        #expect(first == url1 || first == url2)
        
        if let dequeued = first {
            try await actor.markCompleted(urlString: dequeued.absoluteString)
        }
        
        // Save page and verify duplicates
        let sig = MinHashDeduplicator.generateSignature(from: "This is page 1 content.")
        try await actor.savePage(
            urlString: "https://example.com/page1",
            html: "<html></html>",
            text: "This is page 1 content.",
            title: "Page 1",
            signature: sig
        )
        
        let isDup = try await actor.isDuplicate(signature: sig)
        #expect(isDup == true)
    }
}

@Suite("Upgraded Competitor Features Tests")
struct UpgradedCompetitorFeaturesTests {
    @Test("Local Workspace Document Discovery")
    func localWorkspaceSearch() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let file1 = tempDir.appendingPathComponent("file1.md")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let file3 = tempDir.appendingPathComponent("file3.md")
        
        try "This is a document about Apple Intelligence and local LLMs.".write(to: file1, atomically: true, encoding: .utf8)
        try "This text covers database management with SwiftData.".write(to: file2, atomically: true, encoding: .utf8)
        try "Completely unrelated content about baking recipes.".write(to: file3, atomically: true, encoding: .utf8)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        let engine = DiscoveryEngine(localWorkspaceRoots: [tempDir])
        let results = try await engine.search(query: "Apple Intelligence", source: .localWorkspace(directoryPath: tempDir.path))
        #expect(results.count == 1)
        #expect(results.first?.lastPathComponent == "file1.md")
        
        let swiftDataResults = try await engine.search(query: "SwiftData database", source: .localWorkspace(directoryPath: tempDir.path))
        #expect(swiftDataResults.count == 1)
        #expect(swiftDataResults.first?.lastPathComponent == "file2.txt")
    }
    
    @Test("Citation Mapping & Verification")
    func citationMatching() async throws {
        let core = ArchonSemanticCore()
        
        struct TestExtract: Codable, Sendable {
            var coreProduct: String
            var pricing: String
        }
        let extracted = TestExtract(coreProduct: "StealthScraper", pricing: "$49/mo")
        
        let page1 = ScrapedPageData(url: URL(string: "https://example.com/pricing")!, text: "StealthScraper pricing starts at $49/mo for standard developers.")
        let page2 = ScrapedPageData(url: URL(string: "https://example.com/home")!, text: "We deliver advanced Apple Intelligence SDKs.")
        
        let citations = core.matchCitations(for: extracted, scrapedPages: [page1, page2])
        
        #expect(citations.count >= 2)
        #expect(citations.contains { $0.sourceURLString == "https://example.com/pricing" })
    }
    
    @Test("Crawl Path Ancestry Graph")
    func crawlPathAncestry() async throws {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let actor = FrontierQueueActor(modelContainer: container)
        
        let parentURL = URL(string: "https://example.com/parent")!
        let childURL1 = URL(string: "https://example.com/child1")!
        let childURL2 = URL(string: "https://example.com/child2")!
        
        try await actor.enqueue(urls: [parentURL], priority: 10, parentURLString: nil)
        try await actor.enqueue(urls: [childURL1, childURL2], priority: 5, parentURLString: parentURL.absoluteString)
        
        let nodes = try await actor.fetchAllNodes()
        #expect(nodes.count == 3)
        
        let childNodes = nodes.filter { $0.parentURLString == parentURL.absoluteString }
        #expect(childNodes.count == 2)
        #expect(childNodes.contains { $0.urlString == childURL1.absoluteString })
        #expect(childNodes.contains { $0.urlString == childURL2.absoluteString })
    }
    
    @Test("Scraper Selector Whitelist & Blacklist Filtering")
    func scraperSelectorFiltering() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let htmlFile = tempDir.appendingPathComponent("test.html")
        let htmlContent = """
        <html>
        <body>
            <div id="main-content">
                <h1>Article Title</h1>
                <p>Scraped article text content goes here.</p>
                <div class="social-share">Share on Facebook</div>
            </div>
            <div class="sidebar">Related posts and sidebar links</div>
            <footer>Copyright 2026</footer>
        </body>
        </html>
        """
        try htmlContent.write(to: htmlFile, atomically: true, encoding: .utf8)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        let scraper = await StealthScraper(localWorkspaceRoots: [tempDir])
        
        let config = ScrapeConfiguration(
            includeSelectors: ["#main-content"],
            excludeSelectors: [".social-share"]
        )
        
        let result = try await scraper.scrape(url: htmlFile, configuration: config)
        
        #expect(result.text.contains("Scraped article text content goes here"))
        #expect(!result.text.contains("Share on Facebook"))
        #expect(!result.text.contains("Related posts and sidebar links"))
    }
    
    @Test("Queue Exponential Backoff Retries")
    func queueBackoff() async throws {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let actor = FrontierQueueActor(modelContainer: container)
        
        let url = URL(string: "https://example.com/retry-page")!
        try await actor.enqueue(urls: [url], priority: 10)
        
        let dequeued1 = try await actor.dequeueNext()
        #expect(dequeued1 == url)
        
        try await actor.markFailed(urlString: url.absoluteString)
        
        let dequeued2 = try await actor.dequeueNext()
        #expect(dequeued2 == nil) // Node is in cooling backoff
    }
    
    @Test("Stealth User Agent Rotation")
    func userAgentRotation() async throws {
        let ua1 = StealthHeaders.randomUserAgent()
        let ua2 = StealthHeaders.randomUserAgent()
        
        #expect(!ua1.isEmpty)
        #expect(!ua2.isEmpty)
        #expect(ua1.contains("AppleWebKit") || ua1.contains("Mozilla"))
    }
    
    @Test("Queue Exponential Backoff Delay Progression")
    func backoffProgression() async throws {
        let schema = Schema([CrawlNode.self, ScrapedPage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let actor = FrontierQueueActor(modelContainer: container)
        
        let url = URL(string: "https://example.com/retry-progression")!
        try await actor.enqueue(urls: [url], priority: 10)
        
        // Dequeue and fail once
        _ = try await actor.dequeueNext()
        let startTime = Date()
        try await actor.markFailed(urlString: url.absoluteString) // retryCount = 1, delay = 2s
        
        var nodes = try await actor.fetchAllNodes()
        var node = try #require(nodes.first)
        var backoff = try #require(node.backoffUntil)
        #expect(backoff.timeIntervalSince(startTime) >= 1.9)
        
        // Second failure
        try await actor.markFailed(urlString: url.absoluteString) // retryCount = 2, delay = 4s
        nodes = try await actor.fetchAllNodes()
        node = try #require(nodes.first)
        backoff = try #require(node.backoffUntil)
        #expect(backoff.timeIntervalSince(startTime) >= 3.9)
        
        // Third failure
        try await actor.markFailed(urlString: url.absoluteString) // retryCount = 3, status = failed
        nodes = try await actor.fetchAllNodes()
        node = try #require(nodes.first)
        #expect(node.status == "failed")
    }
    
    @Test("Workspace Directory Edge Cases")
    func workspaceEdgeCases() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        let engine = DiscoveryEngine(localWorkspaceRoots: [tempDir])
        
        // 1. Non-existent path
        let nonExistentResults = try await engine.search(
            query: "Apple",
            source: .localWorkspace(directoryPath: tempDir.appendingPathComponent("missing").path)
        )
        #expect(nonExistentResults.isEmpty)

        // 2. Empty directory
        let emptyResults = try await engine.search(query: "Apple", source: .localWorkspace(directoryPath: tempDir.path))
        #expect(emptyResults.isEmpty)
        
        // 3. Empty query matches everything
        let file1 = tempDir.appendingPathComponent("doc1.txt")
        try "Content text here.".write(to: file1, atomically: true, encoding: .utf8)
        
        let allResults = try await engine.search(query: "", source: .localWorkspace(directoryPath: tempDir.path))
        #expect(allResults.count == 1)
        #expect(allResults.first?.lastPathComponent == "doc1.txt")
    }
    
    @Test("Scraper Selector Whitelist & Blacklist Edge Cases")
    func scraperSelectorEdgeCases() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let htmlFile = tempDir.appendingPathComponent("edge.html")
        let htmlContent = """
        <html>
        <body>
            <div id="content">Article text content.</div>
        </body>
        </html>
        """
        try htmlContent.write(to: htmlFile, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        let scraper = await StealthScraper(localWorkspaceRoots: [tempDir])
        
        // 1. Selector whitelisting non-matching elements (should fallback to body text)
        let config1 = ScrapeConfiguration(includeSelectors: [".non-existent-class"])
        let result1 = try await scraper.scrape(url: htmlFile, configuration: config1)
        #expect(result1.text.contains("Article text content"))
        
        // 2. Exclude matching everything (should result in empty markdown or OCR text)
        let config2 = ScrapeConfiguration(excludeSelectors: ["body"])
        let result2 = try await scraper.scrape(url: htmlFile, configuration: config2)
        #expect(result2.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result2.text.contains("[Visual OCR Content]"))
    }
    
    @Test("Orchestrator Timeout Budget and Failure Throws")
    func orchestratorBudgets() async throws {
        let searchEngine = ArchonSearch()
        
        // 1. Verify immediate timeout budget throw
        do {
            _ = try await searchEngine.research(
                query: "Headless CMS",
                extracting: TestResearch.self,
                maxPages: 5,
                timeout: 0.000001
            )
            Issue.record("Expected timeout budget exception but no error was thrown.")
        } catch let error as SearchError {
            switch error {
            case .timeoutBudgetExceeded:
                break // Passed
            default:
                Issue.record("Expected timeoutBudgetExceeded error but got \(error)")
            }
        } catch {
            Issue.record("Expected SearchError but got \(error)")
        }
        
        // 2. Verify throw when no results are found/crawled
        let searchEngine2: ArchonSearch
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        searchEngine2 = ArchonSearch(localWorkspaceRoots: [tempDir])
        
        do {
            _ = try await searchEngine2.research(
                query: "SearchTermThatDoesNotMatchAnything",
                extracting: TestResearch.self,
                source: .localWorkspace(directoryPath: tempDir.path)
            )
            Issue.record("Expected noResultsFound exception but no error was thrown.")
        } catch let error as SearchError {
            switch error {
            case .noResultsFound:
                break // Passed
            default:
                Issue.record("Expected noResultsFound error but got \(error)")
            }
        } catch {
            Issue.record("Expected SearchError but got \(error)")
        }
    }
}
