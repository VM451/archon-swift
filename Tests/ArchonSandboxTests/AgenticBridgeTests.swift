import Testing
import Foundation
@testable import ArchonSandbox

@Suite("AI Agentic Bridge & Tool Calling Tests")
struct AgenticBridgeTests {
    
    @Test("Semantic DOM Extractor script generation and pruning")
    func testSemanticDOMPruning() {
        let script = SemanticDOMExtractor.extractionScript(maxDepth: 5)
        #expect(script.contains("function simplify"))
        #expect(script.contains("SCRIPT"))
        #expect(script.contains("STYLE"))
        
        let sampleJSON = """
        {
            "tag": "div",
            "id": "container",
            "class": "main-card",
            "children": [
                { "tag": "h1", "children": [{ "type": "text", "text": "Hello World" }] },
                { "tag": "button", "id": "submit-btn", "role": "button", "children": [{ "type": "text", "text": "Click Me" }] }
            ]
        }
        """
        
        let markdown = SemanticDOMExtractor.jsonToSemanticMarkdown(sampleJSON)
        #expect(markdown.contains("<[div] #container .main-card>"))
        #expect(markdown.contains("<[h1]>"))
        #expect(markdown.contains("- \"Hello World\""))
        #expect(markdown.contains("<[button] #submit-btn role=\"button\">"))
        
        let pruned = SemanticDOMExtractor.pruneToTokenBudget(markdown, maxTokens: 10)
        #expect(pruned.contains("Truncated for token budget"))
    }
    
    @Test("ToolRegistryActor schema reflection and execution")
    func testToolRegistry() async throws {
        let registry = ToolRegistryActor()
        
        let tool = ClosureAgentTool(
            name: "DeviceBatteryReader",
            description: "Reads current battery level",
            parametersSchemaJSON: "{\"type\":\"object\",\"properties\":{\"unit\":{\"type\":\"string\"}}}"
        ) { args in
            return "{\"battery\": 98, \"unit\": \"percent\"}"
        }
        
        await registry.register(tool)
        let names = await registry.registeredToolNames()
        #expect(names.contains("DeviceBatteryReader"))
        
        let defs = await registry.exportFoundationModelToolDefinitions()
        #expect(defs.count == 1)
        #expect(defs.first?.name == "DeviceBatteryReader")
        
        let result = try await registry.execute(toolName: "DeviceBatteryReader", argumentsJSON: "{\"unit\":\"percent\"}")
        #expect(result.contains("98"))
    }
    
    @Test("AgentPatchResult codable snapshot")
    func testAgentPatchResult() throws {
        let result = AgentPatchResult(
            isSuccess: true,
            executionTimeMs: 14.5,
            rawOutput: "{\"count\": 10}",
            errorDescription: nil
        )
        
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AgentPatchResult.self, from: data)
        
        #expect(decoded.isSuccess == true)
        #expect(decoded.executionTimeMs == 14.5)
        #expect(decoded.rawOutput == "{\"count\": 10}")
        #expect(decoded.errorDescription == nil)
    }
}
