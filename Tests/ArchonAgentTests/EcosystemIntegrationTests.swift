import Testing
import Foundation
@testable import ArchonAgent

@Suite("Archon Ecosystem Capabilities Integration Tests")
struct EcosystemIntegrationTests {

    @Test("ToolRegistry registers all ecosystem capabilities successfully")
    func testRegistryEcosystemCapabilities() {
        let registry = ToolRegistry()
        registry.registerAllEcosystemCapabilities()

        let definitions = registry.definitions()
        let names = Set(definitions.map(\.name))

        #expect(names.contains("memorySearch"))
        #expect(names.contains("memoryStore"))
        #expect(names.contains("coreMemory"))
        #expect(names.contains("sandboxRender"))
        #expect(names.contains("sandboxPatch"))
        #expect(names.contains("sandboxInspectDOM"))
        #expect(names.contains("webSearch"))
        #expect(names.contains("webContents"))
        #expect(names.contains("deepResearch"))
        #expect(names.contains("calculator"))
        #expect(names.contains("fileSystem"))
        #expect(names.contains("deviceInfo"))
    }

    @Test("MemorySearchTool and MemoryStoreTool roundtrip execution")
    func testMemoryTools() async throws {
        let storeActor = TestMemoryStoreActor()
        let storeTool = MemoryStoreTool { fact, _, _ in
            await storeActor.save(fact: fact)
            return "Saved: \(fact)"
        }

        let searchTool = MemorySearchTool { query, _, _ in
            await storeActor.search(query: query)
        }

        let storeResult = try await storeTool.call(argumentsJSON: "{\"fact\": \"Alex lives in Bangkok and builds Swift agents.\"}")
        #expect(storeResult.contains("Saved:"))

        let searchResult = try await searchTool.call(argumentsJSON: "{\"query\": \"Bangkok\"}")
        #expect(searchResult.contains("Alex lives in Bangkok"))
    }


    @Test("CoreMemoryTool sets, gets, and appends working memory blocks")
    func testCoreMemoryTool() async throws {
        let coreTool = CoreMemoryTool()

        let setResult = try await coreTool.call(argumentsJSON: "{\"action\": \"set\", \"blockName\": \"persona\", \"content\": \"Helpful Apple AI Assistant\"}")
        #expect(setResult.contains("Updated block 'persona'"))

        let appendResult = try await coreTool.call(argumentsJSON: "{\"action\": \"append\", \"blockName\": \"persona\", \"content\": \"Expert in Swift 6\"}")
        #expect(appendResult.contains("Appended to block 'persona'"))

        let getResult = try await coreTool.call(argumentsJSON: "{\"action\": \"get\", \"blockName\": \"persona\"}")
        #expect(getResult.contains("Helpful Apple AI Assistant"))
        #expect(getResult.contains("Expert in Swift 6"))
    }

    @Test("SandboxTools render, patch, and inspect DOM structures")
    func testSandboxTools() async throws {
        let renderTool = SandboxRenderTool { html, workspaceName in
            "Sandbox workspace '\(workspaceName ?? "DefaultWorkspace")' successfully rendered HTML (\(html.count) characters)."
        }
        let patchTool = SandboxPatchTool { jsDelta, cssDelta in
            "Sandbox patch applied: JS (\(jsDelta.count) bytes), CSS (\(cssDelta?.count ?? 0) bytes). Execution status: 200 OK."
        }
        let inspectTool = SandboxInspectDOMTool { format, _ in
            format == "json"
                ? "{\"tree\": [{\"tag\": \"div\", \"id\": \"canvas\", \"text\": \"Live UI Component\"}]}"
                : "# Application Root\n- <div id=\"canvas\">Live UI Component</div>"
        }

        let renderRes = try await renderTool.call(argumentsJSON: "{\"html\": \"<div id='app'>Hello World</div>\"}")
        #expect(renderRes.contains("successfully rendered HTML"))

        let patchRes = try await patchTool.call(argumentsJSON: "{\"jsDelta\": \"console.log('patched')\"}")
        #expect(patchRes.contains("Sandbox patch applied"))

        let domMarkdown = try await inspectTool.call(argumentsJSON: "{\"format\": \"markdown\"}")
        #expect(domMarkdown.contains("Live UI Component"))

        let domJSON = try await inspectTool.call(argumentsJSON: "{\"format\": \"json\"}")
        #expect(domJSON.contains("\"tag\": \"div\""))
    }

    @Test("SearchTools perform web search, contents retrieval, and deep research")
    func testSearchTools() async throws {
        let searchTool = WebSearchTool { query in
            "Search results for: \(query)"
        }
        let contentsTool = WebContentsTool { url, _ in
            "# Web Page Content: \(url)"
        }
        let deepResearchTool = DeepResearchAgentTool { query, maxDepth, maxPages in
            "# Deep Research Report: \(query)\nCrawled \(maxPages) pages at depth \(maxDepth).\nCitations"
        }

        let searchRes = try await searchTool.call(argumentsJSON: "{\"query\": \"Swift\"}")
        #expect(searchRes.contains("Search results for: Swift"))

        let contentsRes = try await contentsTool.call(argumentsJSON: "{\"url\": \"https://apple.com/swift\"}")
        #expect(contentsRes.contains("apple.com/swift"))

        let researchRes = try await deepResearchTool.call(argumentsJSON: "{\"query\": \"Swift Concurrency Best Practices\"}")
        #expect(researchRes.contains("Deep Research Report"))
        #expect(researchRes.contains("Citations"))
    }

    struct EcosystemState: AgentState {
        var query: String = ""
        var retrievedMemory: String = ""
        var sandboxOutput: String = ""
        var answer: String = ""
    }

    @Test("Full Agent Graph orchestrates Memory, Search, and Sandbox tools seamlessly")
    func testFullEcosystemAgentGraph() async throws {
        let registry = ToolRegistry()
        registry.registerAllEcosystemCapabilities()
        let dispatcher = ToolDispatcher(registry: registry)

        let builder = GraphBuilder<EcosystemState>()

        builder.addNode("searchMemory") { state in
            var updated = state
            let call = ToolCall(id: "c1", name: "memorySearch", arguments: "{\"query\": \"\(state.query)\"}")
            let res = await dispatcher.execute(call: call)
            updated.retrievedMemory = res.content
            return updated
        }

        builder.addNode("executeSandbox") { state in
            var updated = state
            let call = ToolCall(id: "c2", name: "sandboxRender", arguments: "{\"html\": \"<h1>Agent Output</h1>\"}")
            let res = await dispatcher.execute(call: call)
            updated.sandboxOutput = res.content
            updated.answer = "Pipeline completed successfully."
            return updated
        }

        builder.setEntryPoint("searchMemory")
        builder.addEdge(from: "searchMemory", to: "executeSandbox")
        builder.addEdge(from: "executeSandbox", to: EndNode.id)

        let graph = try builder.compile(checkpointer: InMemoryCheckpointer())
        let finalState = try await graph.invoke(initialState: EcosystemState(query: "Swift UI"))

        #expect(finalState.answer == "Pipeline completed successfully.")
        #expect(!finalState.sandboxOutput.isEmpty)
    }
}

private actor TestMemoryStoreActor {
    private var facts: [String] = []

    func save(fact: String) {
        facts.append(fact)
    }

    func search(query: String) -> String {
        let matching = facts.filter { $0.localizedCaseInsensitiveContains(query) }
        return matching.joined(separator: "\n")
    }
}
