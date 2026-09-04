import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Agent Sandbox Tools & ArchonAgent Integration Tests")
struct AgentSandboxToolsTests {

    @Test("Sandbox tools JSON schema is valid and contains standard tools")
    func testSandboxToolsSchema() {
        let jsonString = ArchonSandboxAgentTools.toolsJSONSchemaString()
        #expect(jsonString.contains("sandbox_render_web_app"))
        #expect(jsonString.contains("sandbox_patch_dom"))
        #expect(jsonString.contains("sandbox_inspect_dom"))
        #expect(jsonString.contains("sandbox_write_file"))
        #expect(jsonString.contains("sandbox_read_file"))
        #expect(jsonString.contains("sandbox_list_files"))
    }

    @Test("handleToolCall writes, lists, and reads virtual files")
    func testVirtualFileOperations() async throws {
        var workspace = SandboxWorkspace(name: "TestSpace", fileMap: [:])

        let writeArgs = "{\"path\": \"app.js\", \"content\": \"console.log('Hello Archon');\"}"
        let writeRes = try await ArchonSandboxAgentTools.handleToolCall(
            workspace: &workspace,
            toolName: "sandbox_write_file",
            argumentsJSON: writeArgs
        )
        #expect(writeRes.contains("Successfully wrote file"))

        let listRes = try await ArchonSandboxAgentTools.handleToolCall(
            workspace: &workspace,
            toolName: "sandbox_list_files",
            argumentsJSON: "{}"
        )
        #expect(listRes.contains("app.js"))

        let readArgs = "{\"path\": \"app.js\"}"
        let readRes = try await ArchonSandboxAgentTools.handleToolCall(
            workspace: &workspace,
            toolName: "sandbox_read_file",
            argumentsJSON: readArgs
        )
        #expect(readRes.contains("console.log('Hello Archon');"))
    }

    @Test("handleToolCall renders web app and updates workspace index.html")
    func testRenderWebApp() async throws {
        var workspace = SandboxWorkspace.defaultTemplate(name: "Demo")

        let renderArgs = "{\"html\": \"<!DOCTYPE html><html><body><h1>Updated by Agent</h1></body></html>\"}"
        let renderRes = try await ArchonSandboxAgentTools.handleToolCall(
            workspace: &workspace,
            toolName: "sandbox_render_web_app",
            argumentsJSON: renderArgs
        )
        #expect(renderRes.contains("Successfully rendered web app"))
        #expect(workspace.file(at: "index.html")?.content.utf8Text?.contains("Updated by Agent") == true)
    }
}

