import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Sandbox Workspace & File Serialization Tests")
struct SandboxWorkspaceTests {
    
    @Test("Workspace initialization and default template creation")
    func testDefaultWorkspaceCreation() {
        let workspace = SandboxWorkspace.defaultTemplate(name: "Test Canvas")
        #expect(workspace.name == "Test Canvas")
        #expect(workspace.entryPointPath == "index.html")
        #expect(workspace.files.count == 1)
        
        let entryFile = workspace.entryPointFile
        #expect(entryFile != nil)
        #expect(entryFile?.path == "index.html")
        #expect(entryFile?.mimeType.contains("text/html") == true)
        #expect(workspace.totalSizeInBytes > 0)
    }
    
    @Test("Virtual file CRUD operations and checksum validation")
    func testFileOperations() {
        var workspace = SandboxWorkspace(name: "Custom App")
        #expect(workspace.files.isEmpty)
        
        let jsFile = SandboxFile(path: "app.js", text: "console.log('Hello World');")
        workspace.upsertFile(jsFile)
        
        #expect(workspace.files.count == 1)
        #expect(workspace.file(at: "app.js")?.path == "app.js")
        #expect(workspace.file(at: "/app.js")?.path == "app.js") // Normalized path lookup
        #expect(workspace.file(at: "app.js")?.checksum.isEmpty == false)
        
        // Update content
        var updatedFile = jsFile
        updatedFile.updateContent(.text("console.log('Updated');"))
        workspace.upsertFile(updatedFile)
        
        #expect(workspace.files.count == 1)
        #expect(workspace.file(at: "app.js")?.content.utf8Text == "console.log('Updated');")
        #expect(workspace.file(at: "app.js")?.checksum != jsFile.checksum)
        
        // Remove file
        let removed = workspace.removeFile(at: "app.js")
        #expect(removed != nil)
        #expect(workspace.files.isEmpty)
    }
    
    @Test("MIME type inference across web file formats")
    func testMimeTypeInference() {
        #expect(SandboxFile.inferMimeType(from: "index.html").contains("text/html"))
        #expect(SandboxFile.inferMimeType(from: "styles.css").contains("text/css"))
        #expect(SandboxFile.inferMimeType(from: "bundle.js").contains("application/javascript"))
        #expect(SandboxFile.inferMimeType(from: "data.json").contains("application/json"))
        #expect(SandboxFile.inferMimeType(from: "compute.wasm") == "application/wasm")
        #expect(SandboxFile.inferMimeType(from: "logo.svg") == "image/svg+xml")
        #expect(SandboxFile.inferMimeType(from: "photo.png") == "image/png")
    }
    
    @Test("Codable serialization of SandboxWorkspace")
    func testWorkspaceCodable() throws {
        let original = SandboxWorkspace.defaultTemplate(name: "Serialize Me")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SandboxWorkspace.self, from: data)
        
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.files.count == original.files.count)
        #expect(decoded.entryPointPath == original.entryPointPath)
    }
    
    @Test("Workspace fileMap dictionary import and export")
    func testFileMapImportExport() {
        let fileMap: [String: String] = [
            "index.html": "<!DOCTYPE html><html><body><h1>Map Test</h1></body></html>",
            "style.css": "body { margin: 0; }",
            "app.js": "console.log('App ready');"
        ]
        
        let workspace = SandboxWorkspace(name: "From Map", fileMap: fileMap)
        #expect(workspace.files.count == 3)
        #expect(workspace.file(at: "style.css")?.content.utf8Text == "body { margin: 0; }")
        
        let exported = workspace.exportFileMap()
        #expect(exported.count == 3)
        #expect(exported["app.js"] == "console.log('App ready');")
    }
}
