import Foundation
import Testing
import GRDB
@testable import ArchonSearch

@Suite("ArchonSearch 2.0 Core, Models, and Persistence Tests")
struct CoreModelsPersistenceTests {
    
    @Test("ArchonSearchConfiguration initializes with localFirst factory and valid defaults")
    func testConfigurationDefaults() {
        let config = ArchonSearchConfiguration.localFirst()
        #expect(config.routingMode == .preferCrawler)
        #expect(config.searchEngine.searxngURL?.absoluteString == "http://localhost:8080")
        #expect(config.crawler.crawl4aiURL?.absoluteString == "http://localhost:11235")
        #expect(config.timeouts.searchTimeout == 8.0)
        #expect(config.limits.maxResults == 10)
    }
    
    @Test("SearchDiagnostics records errors, fetches, and cache hits")
    func testDiagnostics() {
        var diag = SearchDiagnostics()
        #expect(diag.urlFetchCount == 0)
        #expect(diag.cacheHits == 0)
        #expect(diag.errors.isEmpty)
        
        diag.recordFetch()
        diag.recordCacheHit()
        diag.recordError(SearchError.offline)
        
        #expect(diag.urlFetchCount == 1)
        #expect(diag.cacheHits == 1)
        #expect(diag.errors.count == 1)
        #expect(diag.errors.first?.contains("Offline") == true)
    }
    
    @Test("SearchError errorDescription outputs expected descriptions")
    func testSearchErrorDescriptions() {
        let errOffline = SearchError.offline
        let errSearx = SearchError.searxng(reason: "timeout")
        let errCrawl = SearchError.crawl4ai(reason: "404")
        
        #expect(errOffline.errorDescription?.contains("Offline") == true)
        #expect(errSearx.errorDescription?.contains("SearXNG") == true)
        #expect(errCrawl.errorDescription?.contains("Crawl4AI") == true)
    }
    
    @Test("Models instantiation and encoding")
    func testModels() throws {
        let url = URL(string: "https://example.com/test")!
        let doc = WebDocument(url: url, title: "Test Doc", text: "Some body text", markdown: "# Header")
        #expect(doc.title == "Test Doc")
        
        let sourceID = UUID()
        let passage = SourcePassage(sourceID: sourceID, text: "Sample passage", score: 0.95)
        let source = Source(id: sourceID, url: url, title: "Source Title", passages: [passage])
        #expect(source.passages.count == 1)
        
        let citation = Citation(label: "[1]", sourceID: sourceID, passageID: passage.passageID, url: url, title: "Source Title", snippet: "Sample passage")
        #expect(citation.index == 1)
        
        let report = ResearchReport(query: "swift 6", summary: "Summary", sources: [source], citations: [citation])
        #expect(report.query == "swift 6")
        
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ResearchReport.self, from: encoded)
        #expect(decoded.query == report.query)
    }
    
    @Test("In-memory SearchDatabase and Repositories persist and fetch records")
    func testDatabaseAndRepositories() async throws {
        let db = try SearchDatabase(inMemory: true)
        
        // Conversations
        let convRepo = GRDBConversationRepository(database: db)
        try await convRepo.saveConversation(id: "conv-1", title: "Swift Concurrency")
        let fetchedConv = try await convRepo.fetchConversation(id: "conv-1")
        #expect(fetchedConv?.title == "Swift Concurrency")
        
        try await convRepo.saveMessage(id: "msg-1", conversationId: "conv-1", role: "user", content: "Hello")
        let messages = try await convRepo.fetchMessages(conversationId: "conv-1")
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
        
        // Sources & Citations
        let sourceRepo = GRDBSourceRepository(database: db)
        let sourceID = UUID()
        let url = URL(string: "https://example.com")!
        let passage = SourcePassage(sourceID: sourceID, text: "Passage")
        let source = Source(id: sourceID, url: url, title: "Example", passages: [passage])
        try await sourceRepo.saveSource(source, sessionId: "session-1")
        
        let sources = try await sourceRepo.fetchSources(sessionId: "session-1")
        #expect(sources.count == 1)
        #expect(sources.first?.title == "Example")
        
        let citation = Citation(label: "[1]", sourceID: sourceID, url: url, title: "Example", snippet: "Passage")
        try await sourceRepo.saveCitation(citation)
        let citations = try await sourceRepo.fetchCitations(sourceId: sourceID)
        #expect(citations.count == 1)
        #expect(citations.first?.label == "[1]")
        
        // Cache
        let cacheRepo = GRDBCacheRepository(database: db)
        let doc = WebDocument(url: url, title: "Doc", text: "Body")
        try await cacheRepo.setCachedDocument(doc, ttl: 3600)
        let cached = try await cacheRepo.getCachedDocument(url: url)
        #expect(cached?.title == "Doc")
        
        try await cacheRepo.evictExpired()
        let stillCached = try await cacheRepo.getCachedDocument(url: url)
        #expect(stillCached != nil)
    }
}
