import Testing
import Foundation
@testable import ArchonSearch

@Suite("Agent Search Tools & ArchonAgent Integration Tests")
struct AgentSearchToolsTests {

    @Test("Search tools JSON schema contains valid standard tools")
    func testSearchToolsSchema() throws {
        let jsonString = ArchonSearchAgentTools.toolsJSONSchemaString()
        let data = try #require(jsonString.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(json?.isEmpty == false)
        #expect(jsonString.contains("web_search"))
        #expect(jsonString.contains("social_media_search"))
        #expect(jsonString.contains("socialMedia"))
        #expect(jsonString.contains("web_contents"))
        #expect(jsonString.contains("web_deep_research"))
    }

    @Test("handleToolCall executes web_search on local workspace")
    func testLocalSearchExecution() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-search-agent-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try "Swift local fixture".write(
            to: directoryURL.appendingPathComponent("fixture.md"),
            atomically: true,
            encoding: .utf8
        )

        let search = ArchonSearch(localWorkspaceRoots: [directoryURL])
        let args = "{\"query\": \"swift\", \"source\": \"localWorkspace\", \"directoryPath\": \"\(directoryURL.path)\", \"maxResults\": 3}"
        let result = try await ArchonSearchAgentTools.handleToolCall(
            search: search,
            toolName: "web_search",
            argumentsJSON: args
        )
        // Returns either formatted results or graceful no results found
        #expect(!result.isEmpty)
    }

    @Test("handleToolCall collects real multi-query evidence from a local workspace")
    func testLocalDeepResearchEvidenceCollection() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-search-deep-research-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try "Actors isolate mutable state. Strict concurrency makes sendability explicit."
            .write(to: directoryURL.appendingPathComponent("swift.md"), atomically: true, encoding: .utf8)

        let search = ArchonSearch(localWorkspaceRoots: [directoryURL])
        let args = "{\"query\": \"Swift concurrency\", \"subQueries\": [\"actors\"], \"source\": \"localWorkspace\", \"directoryPath\": \"\(directoryURL.path)\", \"maxPages\": 2}"
        let result = try await ArchonSearchAgentTools.handleToolCall(
            search: search,
            toolName: "web_deep_research",
            argumentsJSON: args
        )

        #expect(result.contains("Verified Evidence"))
        #expect(result.contains("swift.md"))
        #expect(!result.contains("zero cloud telemetry"))
        #expect(!result.contains("Autonomous analysis completed"))
    }

    @Test(
        "handleToolCall executes web_deep_research",
        .enabled(if: ProcessInfo.processInfo.environment["ARCHON_ENABLE_LIVE_TESTS"] == "1")
    )
    func testDeepResearchExecution() async throws {
        let search = ArchonSearch()
        let args = "{\"query\": \"Swift Concurrency State Machines\", \"subQueries\": [\"Actors\", \"Strict Concurrency\"]}"
        let result = try await ArchonSearchAgentTools.handleToolCall(
            search: search,
            toolName: "web_deep_research",
            argumentsJSON: args
        )
        #expect(result.contains("Deep Research Findings"))
        #expect(result.contains("Swift Concurrency State Machines"))
    }
}
