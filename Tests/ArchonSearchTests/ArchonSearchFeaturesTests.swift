import Testing
import Foundation
@testable import ArchonSearch

@Suite("Search, Contents & Feature API Tests")
struct ArchonSearchFeaturesTests {

    private func makeEngine() -> ArchonSearch {
        ArchonSearch { _, _, _ in
            Data(#"{"coreProduct":"Headless CMS Platform","pricing":"$49/mo","mission":"Injected test result"}"#.utf8)
        }
    }
    
    private func makeTempHTMLDirectory(fileName: String, content: String) throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let htmlFile = tempDir.appendingPathComponent(fileName)
        try content.write(to: htmlFile, atomically: true, encoding: .utf8)
        return tempDir
    }
    
    @Test("Search returns title, snippet and highlights from local files")
    func searchLocalWorkspace() async throws {
        let content = """
        <html>
        <head><title>Apple Intelligence</title></head>
        <body>
            <p>Apple Intelligence delivers personalized experiences on device.</p>
            <p>The capital of France is Paris, known for art and fashion.</p>
        </body>
        </html>
        """
        let tempDir = try makeTempHTMLDirectory(fileName: "apple.md", content: content)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let engine = makeEngine()
        let results = try await engine.search(
            query: "Apple Intelligence",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxResults: 5,
            livecrawl: .fast
        )
        
        #expect(results.count == 1)
        let firstSearch = try #require(results.first)
        #expect(firstSearch.title == "Apple Intelligence")
        #expect(firstSearch.snippet.localizedCaseInsensitiveContains("Apple") == true)
        #expect(!firstSearch.highlights.isEmpty)
    }

    @Test("Provider contract keeps local-only search off the network")
    func providerNetworkPolicy() async throws {
        let content = "Local Archon memory and offline search."
        let tempDir = try makeTempHTMLDirectory(fileName: "local.md", content: content)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ArchonSearchProvider(engine: makeEngine())
        let response = try await provider.search(SearchRequest(
            query: "offline search",
            source: .localWorkspace(directoryPath: tempDir.path)
        ))
        #expect(response.providerID == "archon.search")
        #expect(response.usedNetwork == false)
        #expect(response.results.count == 1)

        await #expect(throws: SearchError.localOnlyRequiresLocalSource) {
            _ = try await provider.search(SearchRequest(
                query: "network must be explicit",
                source: .duckDuckGo
            ))
        }

        await #expect(throws: SearchError.localOnlyRequiresStaticLocalCrawl) {
            _ = try await provider.search(SearchRequest(
                query: "dynamic local crawl must be explicit",
                source: .localWorkspace(directoryPath: tempDir.path),
                livecrawl: .full(scrapeConfig: ScrapeConfiguration())
            ))
        }
    }

    @Test("LocalSearchIndex supports deterministic offline corpus search and persistence")
    func localCorpusSearch() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-local-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let index = try LocalSearchIndex(storageURL: storageURL)
        let document = LocalSearchDocument(
            url: URL(fileURLWithPath: "/tmp/archon.md"),
            title: "Offline Memory",
            content: "Local-first retrieval stays on the device."
        )
        try await index.upsert(document)

        let provider = LocalSearchIndexProvider(index: index)
        let response = try await provider.search(SearchRequest(
            query: "local retrieval",
            source: .localWorkspace(directoryPath: "/tmp"),
            networkPolicy: .localOnly
        ))

        #expect(response.usedNetwork == false)
        #expect(response.results.first?.url == document.url)

        let reopened = try LocalSearchIndex(storageURL: storageURL)
        #expect(await reopened.count == 1)
    }

    @Test("Local workspace discovery cooperates with task cancellation")
    func localWorkspaceSearchCancellation() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let task = Task {
            try await DiscoveryEngine().search(
                query: "cancel",
                source: .localWorkspace(directoryPath: tempDir.path)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected local workspace discovery to observe cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }
    
    @Test("Contents returns full page text, html and highlights")
    func contentsLocalWorkspace() async throws {
        let content = """
        <html>
        <head><title>SwiftData Overview</title></head>
        <body>
            <p>SwiftData manages data storage in native Swift apps.</p>
            <p>Models are persisted using the SwiftData framework.</p>
        </body>
        </html>
        """
        let tempDir = try makeTempHTMLDirectory(fileName: "swiftdata.md", content: content)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let engine = makeEngine()
        let results = try await engine.contents(
            query: "SwiftData storage",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxPages: 1,
            livecrawl: .fast,
            maxHighlights: 2
        )
        
        #expect(results.count == 1)
        let firstContent = try #require(results.first)
        #expect(firstContent.title == "SwiftData Overview")
        #expect(firstContent.markdown.localizedCaseInsensitiveContains("SwiftData") == true)
        #expect(firstContent.highlights.count <= 2)
    }

    @Test("Search and contents honor an already-expired latency budget")
    func expiredLatencyBudgetReturnsWithoutEnrichment() async throws {
        let tempDir = try makeTempHTMLDirectory(
            fileName: "budget.md",
            content: "<html><head><title>Budget</title></head><body><p>Budget test content.</p></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = makeEngine()
        let searchResults = try await engine.search(
            query: "budget",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxResults: 1,
            livecrawl: .fast,
            latency: 0
        )
        let contentResults = try await engine.contents(
            query: "budget",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxPages: 1,
            livecrawl: .fast,
            timeout: 0
        )

        #expect(searchResults.isEmpty)
        #expect(contentResults.isEmpty)
    }

    @Test("Search clamps a negative result limit instead of trapping")
    func negativeSearchLimitIsEmpty() async throws {
        let tempDir = try makeTempHTMLDirectory(fileName: "bounded.md", content: "bounded search content")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyResults = try await makeEngine().search(
            query: "bounded",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxResults: -1,
            livecrawl: .fast
        )
        let boundedResults = try await makeEngine().search(
            query: "bounded",
            source: .localWorkspace(directoryPath: tempDir.path),
            maxResults: 1,
            maxSnippetCharacters: -1,
            maxHighlights: -1,
            livecrawl: .fast
        )

        #expect(emptyResults.isEmpty)
        #expect(boundedResults.count == 1)
        #expect(boundedResults[0].highlights.isEmpty)
    }
    
    @Test("Deep search runs multi-step workflow and returns structured answer")
    func deepSearchMultiStep() async throws {
        let content1 = """
        <html>
        <head><title>Headless CMS</title></head>
        <body>
            <p>Headless CMS Platform starting at $49/mo to build a highly robust developer experience.</p>
        </body>
        </html>
        """
        let tempDir = try makeTempHTMLDirectory(fileName: "cms.md", content: content1)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let engine = makeEngine()
        let output = try await engine.deepSearch(
            query: "Top headless CMS startups 2026",
            subQueries: ["cms"],
            extracting: TestResearch.self,
            maxPagesPerStep: 1,
            source: .localWorkspace(directoryPath: tempDir.path),
            timeout: 120.0
        )
        
        #expect(output.steps.count >= 1)
        #expect(output.finalAnswer.coreProduct.localizedCaseInsensitiveContains("Headless") == true)
        #expect(output.allCitations.isEmpty == false)
    }
    
    @Test("Agent builds a list of structured items from local files")
    func buildListFromLocalWorkspace() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let page1 = """
        <html><head><title>Product One</title></head>
        <body><p>Product One is a headless CMS priced at $49/mo.</p></body>
        </html>
        """
        let page2 = """
        <html><head><title>Product Two</title></head>
        <body><p>Product Two is an on-device search engine with open source pricing.</p></body>
        </html>
        """
        try page1.write(to: tempDir.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try page2.write(to: tempDir.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let engine = makeEngine()
        let list = try await engine.buildList(
            query: "product",
            itemType: TestResearch.self,
            targetCount: 2,
            maxPages: 5,
            source: .localWorkspace(directoryPath: tempDir.path),
            timeout: 120.0
        )
        
        #expect(list.items.count >= 1)
        #expect(!list.citations.isEmpty)
    }
    
    @Test("Monitor starts, yields an event, and stops")
    func monitorLifecycle() async throws {
        let content = """
        <html>
        <head><title>Monitor Test</title></head>
        <body><p>Local search and monitoring with ArchonSearch.</p></body>
        </html>
        """
        let tempDir = try makeTempHTMLDirectory(fileName: "monitor.md", content: content)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let engine = ArchonSearch()
        let monitor = engine.startMonitor(
            query: "ArchonSearch",
            cadence: 0.2,
            source: .localWorkspace(directoryPath: tempDir.path),
            maxResults: 5,
            livecrawl: .fast
        )
        
        let stream = await monitor.events
        await monitor.start()
        
        let event = try await withThrowingTaskGroup(of: ArchonSearchMonitor.Event?.self) { group in
            group.addTask {
                return await stream.first(where: { _ in true })
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        
        await monitor.stop()
        #expect(event != nil)
        #expect(event?.newResults.isEmpty == false)
    }
}
