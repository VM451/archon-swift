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

    @Test("Function dispatch accepts JSON values and rejects executable syntax")
    func testSafeFunctionDispatch() async throws {
        let engine = SandboxEngine(workspace: SandboxWorkspace.defaultTemplate(name: "Dispatch Test"))
        await engine.bindEvaluator { script in script }

        let script = try await engine.dispatchFunctionCall(
            name: "window.renderCard",
            args: [#"{"title":"'); window.evil()"}"#, "42"]
        )
        #expect(script.contains("window.renderCard"))
        #expect(script.contains("window.evil()"))

        let lineSeparatorScript = try await engine.dispatchFunctionCall(
            name: "window.renderCard",
            args: ["\"line\u{2028}separator\""]
        )
        #expect(lineSeparatorScript.utf8.contains(0xE2) == false)
        #expect(lineSeparatorScript.range(of: #"\u2028"#) != nil)

        await #expect(throws: SandboxError.self) {
            _ = try await engine.dispatchFunctionCall(name: "window.renderCard;window.evil", args: ["42"])
        }
        await #expect(throws: SandboxError.self) {
            _ = try await engine.dispatchFunctionCall(name: "window.renderCard", args: ["42); window.evil()"])
        }
    }

    @Test("Execution provider reports its real local isolation boundary")
    func inProcessExecutionProvider() async throws {
        let engine = SandboxEngine(workspace: SandboxWorkspace.defaultTemplate(name: "Execution Provider"))
        await engine.bindEvaluator { script in "evaluated:\(script)" }
        let provider = InProcessWebKitExecutionProvider(engine: engine)

        let result = try await provider.execute(SandboxExecutionRequest(script: "1 + 1"))
        #expect(result.output == "evaluated:1 + 1")
        #expect(result.isolationLevel == .inProcessWebKit)
        #expect(result.networkAccessPermitted == false)
        #expect(provider.isNetworkDependent == false)

        await #expect(throws: SandboxError.invalidExecutionRequest("Script must not be empty.")) {
            _ = try await provider.execute(SandboxExecutionRequest(script: "   "))
        }
    }

    @Test("DOM patch selectors and style IDs are escaped as string literals")
    func testDOMPatcherEscapesSelectors() {
        let selector = "#card'); window.evil();//"
        let script = DOMPatcher.generateSubtreePatchScript(selector: selector, newHTML: "<p>safe</p>")
        let styleScript = DOMPatcher.generateCSSPatchScript(css: "body {}", styleTagID: "style'); window.evil();//")

        #expect(script.contains("querySelector('#card\\'); window.evil();//')"))
        #expect(styleScript.contains("getElementById('style\\'); window.evil();//')"))
        #expect(!script.contains("querySelector('#card'); window.evil();//')"))
        #expect(!styleScript.contains("getElementById('style'); window.evil();//')"))
    }
}
