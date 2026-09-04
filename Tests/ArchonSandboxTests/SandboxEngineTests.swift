import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Sandbox Engine Actor & Event Stream Tests")
struct SandboxEngineTests {
    
    @Test("SandboxEngine actor lifecycle and tool registration")
    func testEngineToolLifecycle() async throws {
        let workspace = SandboxWorkspace.defaultTemplate(name: "Actor Test")
        let engine = SandboxEngine(workspace: workspace)
        
        let tool = ClosureAgentTool(
            name: "MathAdder",
            description: "Adds numbers",
            parametersSchemaJSON: "{\"type\":\"object\"}"
        ) { args in
            return "{\"result\": 42}"
        }
        
        await engine.registerTool(tool)
        let toolNames = await engine.getRegisteredToolNames()
        #expect(toolNames.contains("MathAdder"))
        
        let retrieved = await engine.getTool(named: "MathAdder")
        #expect(retrieved != nil)
        #expect(retrieved?.name == "MathAdder")
        
        let execResult = try await retrieved?.execute(argumentsJSON: "{}")
        #expect(execResult?.contains("42") == true)
        
        await engine.removeTool(named: "MathAdder")
        let afterRemove = await engine.getRegisteredToolNames()
        #expect(afterRemove.isEmpty)
    }
    
    @Test("Event stream emission and consumption")
    func testEventStream() async throws {
        let workspace = SandboxWorkspace.defaultTemplate(name: "Stream Test")
        let engine = SandboxEngine(workspace: workspace)
        
        // Emit events
        await engine.emitEvent(.consoleLog(level: .info, message: "Test log message", timestamp: Date()))
        await engine.emitEvent(.uncaughtError(message: "Simulated runtime error", stackTrace: nil))
        await engine.emitEvent(.customMessage(name: "BridgeReady", payload: "{}"))
        
        // Read from event stream
        var events: [SandboxEvent] = []
        var iterator = engine.eventStream.makeAsyncIterator()
        
        // First is lifecycle initializing
        if let first = await iterator.next() {
            events.append(first)
        }
        if let second = await iterator.next() {
            events.append(second)
        }
        
        #expect(events.count == 2)
        #expect(events[0] == .lifecycle(.initializing))
    }
    
    @Test("DOM Patcher script generation")
    func testDOMPatcher() {
        let cssScript = DOMPatcher.generateCSSPatchScript(css: "body { background: red; }")
        #expect(cssScript.contains("sandbox-dynamic-styles"))
        #expect(cssScript.contains("body { background: red; }"))
        
        let subtreeScript = DOMPatcher.generateSubtreePatchScript(selector: "#app", newHTML: "<h1>New Title</h1>")
        #expect(subtreeScript.contains("querySelector('#app')"))
        #expect(subtreeScript.contains("<h1>New Title</h1>"))
        
        let jsPatch = DOMPatcher.generateJSPatchScript(jsCode: "return 1 + 1;")
        #expect(jsPatch.contains("performance.now()"))
        #expect(jsPatch.contains("return 1 + 1;"))
    }
}
