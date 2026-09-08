import Testing
import Foundation
@testable import ArchonSearch

@Suite("ArchonSearchClient & UI Facade Tests")
struct ArchonSearchClientTests {

    @Test("ArchonSearchClient initializes with localFirst configuration")
    func clientInitialization() async {
        let config = ArchonSearchConfiguration.localFirst()
        let client = ArchonSearchClient(configuration: config)
        let configRead = await client.configuration

        #expect(configRead.routingMode == .preferCrawler)
        #expect(configRead.searchEngine.searxngURL?.absoluteString == "http://localhost:8080")
        #expect(configRead.crawler.crawl4aiURL?.absoluteString == "http://localhost:11235")
    }

    @Test("ArchonChatMessage value semantics and role conformance")
    func chatMessageSemantics() {
        let citation = Citation(
            label: "[1]",
            sourceID: UUID(),
            url: URL(string: "https://example.com/swift") ?? URL(fileURLWithPath: "/"),
            title: "Swift Org"
        )
        let msg = ArchonChatMessage(
            role: .assistant,
            content: "Swift is a general-purpose programming language. [1]",
            citations: [citation]
        )

        #expect(msg.role == .assistant)
        #expect(msg.citations.count == 1)
        #expect(msg.citations[0].label == "[1]")
    }

    @Test("ArchonChatViewModel state management and initial values")
    @MainActor
    func viewModelInitialization() {
        let client = ArchonSearchClient(configuration: .localFirst())
        let viewModel = ArchonChatViewModel(client: client)

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.inputText == "")
        #expect(viewModel.mode == .standard)
        #expect(!viewModel.isSearching)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("SearchComposerMode raw values and identity")
    func composerModes() {
        #expect(SearchComposerMode.standard.rawValue == "Search")
        #expect(SearchComposerMode.deepResearch.rawValue == "Deep Research")
        #expect(SearchComposerMode.allCases.count == 2)
    }
}
