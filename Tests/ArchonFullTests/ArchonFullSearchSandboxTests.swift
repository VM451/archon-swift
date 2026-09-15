import Testing
import Foundation
@testable import ArchonFull

@Suite("ArchonFull Search+Sandbox Coverage")
struct ArchonFullSearchSandboxTests {

    @Test("Re-exported search configuration factories visible via Full")
    func searchReExport() {
        #expect(ArchonSearchConfiguration.onDevice().routingMode == .nativeOnly)
        let err: SearchError = .noResultsFound
        #expect(!err.description.isEmpty)
    }

    @Test("Re-exported sandbox configuration and workspace visible via Full")
    func sandboxReExport() {
        #expect(SandboxConfiguration.secure.maxMemoryMB == 128)
        var ws = SandboxWorkspace(name: "full", fileMap: ["index.html": "<h1>hi</h1>"])
        #expect(ws.entryPointFile != nil)
        ws.upsertFile(SandboxFile(path: "a.txt", text: "x"))
        #expect(ws.file(at: "a.txt") != nil)
        #expect(ws.removeFile(at: "a.txt") != nil)
        #expect(ws.file(at: "a.txt") == nil)
    }

    @Test("Re-exported error and CRDT merge work via Full")
    func errorAndMergeViaFull() throws {
        let local = SandboxWorkspace(name: "l", fileMap: ["f.html": "one"])
        let remote = SandboxWorkspace(name: "r", fileMap: ["f.html": "one", "g.html": "two"])
        let result = WorkspaceCRDT.merge(local: local, remote: remote)
        #expect(result.filesAdded.contains("g.html") || result.filesPreserved.contains("f.html"))
        let chunked = AssetChunkManager.chunkData(Data("full".utf8), chunkSize: 2)
        #expect(try AssetChunkManager.reassembleChunks(chunked) == Data("full".utf8))
    }

    @Test("Local-only search index usable via Full re-export")
    func localIndexViaFull() async throws {
        let index = try LocalSearchIndex()
        try await index.upsert(LocalSearchDocument(
            url: URL(string: "https://example.com/full")!,
            title: "Full stack check",
            content: "integration coverage"
        ))
        #expect(try await index.search(query: "coverage", limit: 5).count == 1)
        await #expect(throws: LocalSearchIndexError.invalidLimit(999)) {
            try await index.search(query: "coverage", limit: 999)
        }
    }

    @Test("CSP builder reachable via Full; cancelled task surfaces CancellationError")
    func policyAndCancellation() async {
        #expect(SandboxCSPBuilder.buildPolicy(configuration: .default).contains("default-src"))
        let task: Task<Void, Error> = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
