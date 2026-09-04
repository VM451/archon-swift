import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Workspace CRDT & Conflict Resolution Tests")
struct WorkspaceCRDTTests {
    
    @Test("CRDT Last-Write-Wins (LWW) file level merge")
    func testLWWMerge() {
        let baseDate = Date()
        let oldDate = baseDate.addingTimeInterval(-100)
        let newDate = baseDate.addingTimeInterval(100)
        
        let localFile = SandboxFile(
            path: "index.html",
            content: .text("<h1>Local Content</h1>"),
            lastModified: oldDate
        )
        let local = SandboxWorkspace(
            name: "Local Workspace",
            files: [localFile],
            lastModified: oldDate
        )
        
        let remoteFile = SandboxFile(
            path: "index.html",
            content: .text("<h1>Remote Content</h1>"),
            lastModified: newDate
        )
        let remoteNewFile = SandboxFile(
            path: "style.css",
            content: .text("body { color: blue; }"),
            lastModified: newDate
        )
        let remote = SandboxWorkspace(
            name: "Remote Workspace",
            files: [remoteFile, remoteNewFile],
            lastModified: newDate
        )
        
        let mergeResult = WorkspaceCRDT.merge(local: local, remote: remote)
        let merged = mergeResult.mergedWorkspace
        
        // Remote index.html was newer, so it should win
        #expect(merged.file(at: "index.html")?.content.utf8Text == "<h1>Remote Content</h1>")
        // style.css was added from remote
        #expect(merged.file(at: "style.css") != nil)
        #expect(mergeResult.filesAdded.contains("style.css"))
        #expect(mergeResult.filesUpdated.contains("index.html"))
        #expect(mergeResult.conflictsResolved == 1)
    }
    
    @Test("AssetChunkManager splits and reassembles binary data accurately")
    func testAssetChunking() throws {
        // Generate 2MB random binary data (e.g. WASM simulation)
        var sampleBytes = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
        for i in 0..<sampleBytes.count {
            sampleBytes[i] = UInt8(i % 256)
        }
        let originalData = Data(sampleBytes)
        
        let chunks = AssetChunkManager.chunkData(originalData, chunkSize: 512 * 1024)
        #expect(chunks.count == 4)
        #expect(chunks[0].descriptor.chunkIndex == 0)
        #expect(chunks[0].descriptor.totalChunks == 4)
        
        let reassembled = try AssetChunkManager.reassembleChunks(chunks)
        #expect(reassembled == originalData)
    }
}
