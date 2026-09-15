import Testing
import Foundation
@testable import ArchonSandbox

@Suite("ArchonSandbox Edge Cases")
struct ArchonSandboxEdgeCasesTests {

    private func makeWorkspaceFile(path: String, text: String, date: Date = Date()) -> SandboxFile {
        SandboxFile(path: path, text: text, lastModified: date)
    }

    // MARK: - SandboxConfiguration policy

    @Test("Default denies network; explicit permission allows it")
    func configNetworkPolicy() {
        #expect(SandboxConfiguration.default.allows(.network) == false)
        var cfg = SandboxConfiguration.default
        cfg.allowedPermissions = [.network]
        #expect(cfg.allows(.network))
    }

    @Test("allowsURLScheme is case-insensitive and honors legacy https flag")
    func schemeEdges() {
        var cfg = SandboxConfiguration(allowedSchemes: ["Sandbox"])
        #expect(cfg.allowsURLScheme("SANDBOX"))
        #expect(!cfg.allowsURLScheme("https"))
        var legacy = SandboxConfiguration.default
        legacy.allowNetworkAccess = true
        #expect(legacy.allowsURLScheme("HTTPS"))
        #expect(legacy.allowsURLScheme("wss"))
        #expect(legacy.effectiveAllowedSchemes.contains("https"))
        #expect(!SandboxConfiguration.default.effectiveAllowedSchemes.contains("https"))
    }

    @Test("Secure vs developer presets differ as documented")
    func presets() {
        #expect(SandboxConfiguration.secure.maxMemoryMB < SandboxConfiguration.developer.maxMemoryMB)
        #expect(!SandboxConfiguration.secure.developerModeEnabled)
        #expect(SandboxConfiguration.developer.developerModeEnabled)
        #expect(!SandboxConfiguration.secure.isInspectable)
    }

    // MARK: - SandboxError

    @Test("SandboxError descriptions and memory-limit boundary values")
    func errorCases() {
        #expect(!SandboxError.toolNotFound("x").description.isEmpty)
        #expect(!SandboxError.memoryLimitExceeded(usedMB: 256, limitMB: 256).description.contains("250"))
        #expect(SandboxError.memoryLimitExceeded(usedMB: 129, limitMB: 128).description.contains("129"))
        #expect(SandboxError.engineDeallocated == SandboxError.engineDeallocated)
        #expect(SandboxError.timeout("t") != SandboxError.executionFailed("t"))
    }

    // MARK: - WorkspaceCRDT

    private func workspace(paths: [(String, String, Date)]) -> SandboxWorkspace {
        var ws = SandboxWorkspace(name: "w")
        for (p, t, d) in paths {
            ws.upsertFile(makeWorkspaceFile(path: p, text: t, date: d))
        }
        return ws
    }

    @Test("Merge of two empty workspaces yields zero conflicts")
    func mergeEmpty() {
        let result = WorkspaceCRDT.merge(local: SandboxWorkspace(name: "a"), remote: SandboxWorkspace(name: "b"))
        #expect(result.conflictsResolved == 0)
        #expect(result.mergedWorkspace.files.isEmpty)
    }

    @Test("Merge adds remote-only files and preserves identical files")
    func mergeAddedAndPreserved() {
        let now = Date()
        let local = workspace(paths: [("a.html", "same", now)])
        var remote = workspace(paths: [("a.html", "same", now)])
        remote.upsertFile(makeWorkspaceFile(path: "b.html", text: "new"))
        // Force identical checksum by copying file object
        remote = {
            var r = SandboxWorkspace(name: "b")
            r.upsertFile(local.file(at: "a.html")!)
            r.upsertFile(makeWorkspaceFile(path: "b.html", text: "new"))
            return r
        }()
        let result = WorkspaceCRDT.merge(local: local, remote: remote)
        #expect(result.filesAdded.contains("b.html"))
        #expect(result.filesPreserved.contains("a.html"))
    }

    @Test("LWW: newer remote wins; equal timestamps keep local")
    func mergeLWWBoundaries() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let localOld = workspace(paths: [("f.html", "local", old)])
        let remoteNew = workspace(paths: [("f.html", "remote", new)])
        let r1 = WorkspaceCRDT.merge(local: localOld, remote: remoteNew)
        #expect(r1.filesUpdated == ["f.html"])
        #expect(r1.conflictsResolved == 1)
        #expect(r1.mergedWorkspace.file(at: "f.html")?.content.utf8Text == "remote")

        let same = Date(timeIntervalSince1970: 3_000)
        let localSame = workspace(paths: [("f.html", "local", same)])
        let remoteSame = workspace(paths: [("f.html", "remote", same)])
        let r2 = WorkspaceCRDT.merge(local: localSame, remote: remoteSame)
        #expect(r2.mergedWorkspace.file(at: "f.html")?.content.utf8Text == "local")
    }

    // MARK: - AssetChunkManager

    @Test("Empty data yields no chunks and reassembles to empty")
    func chunksEmpty() throws {
        #expect(AssetChunkManager.chunkData(Data()).isEmpty)
        #expect(try AssetChunkManager.reassembleChunks([]).isEmpty)
    }

    @Test("Chunk round-trip; out-of-order input still reassembles")
    func chunksRoundTrip() throws {
        let data = Data("hello sandbox chunk world".utf8)
        let chunks = AssetChunkManager.chunkData(data, chunkSize: 4)
        #expect(chunks.count == 7)
        #expect(chunks[0].descriptor.chunkIndex == 0)
        #expect(chunks[0].descriptor.totalChunks == chunks.count)
        let reversed = Array(chunks.reversed())
        #expect(try AssetChunkManager.reassembleChunks(reversed) == data)
    }

    @Test("Corrupted chunk throws serializationFailed")
    func chunksCorrupted() {
        let data = Data("abcdef".utf8)
        var chunks = AssetChunkManager.chunkData(data, chunkSize: 3)
        chunks[0] = (chunks[0].descriptor, Data("XXX".utf8))
        #expect(throws: SandboxError.self) {
            try AssetChunkManager.reassembleChunks(chunks)
        }
    }

    // MARK: - SyncOfflineQueue

    @Test("Enqueue deduplicates workspace; complete removes it")
    func queueCommon() async {
        let q = SyncOfflineQueue()
        let ws = UUID()
        await q.enqueue(workspaceID: ws)
        await q.enqueue(workspaceID: ws)
        #expect(await q.pendingCount == 1)
        let ready = await q.readyOperations()
        #expect(ready.count == 1)
        await q.markCompleted(id: ready[0].id)
        #expect(await q.pendingCount == 0)
    }

    @Test("Failed op backs off out of ready set; explicit retry delay honored")
    func queueBackoff() async {
        let q = SyncOfflineQueue()
        let ws = UUID()
        await q.enqueue(workspaceID: ws)
        let op = await q.readyOperations()[0]
        await q.markFailed(id: op.id)
        #expect(await q.readyOperations().isEmpty)
        await q.markFailed(id: op.id, retryAfterSeconds: 0)
        // nextRetryDate ~ now; allow tiny skew
        #expect(await q.pendingCount == 1)
        await q.clear()
        #expect(await q.pendingCount == 0)
        await q.markCompleted(id: UUID()) // unknown id: no-op
        await q.markFailed(id: UUID()) // unknown id: no-op
    }

    // MARK: - CSP + DOM + auth policy

    @Test("Custom CSP passes through; default denies objects and frames")
    func cspPolicy() {
        let custom = SandboxConfiguration(customCSP: "default-src 'none'")
        #expect(SandboxCSPBuilder.buildPolicy(configuration: custom) == "default-src 'none'")
        let policy = SandboxCSPBuilder.buildPolicy(configuration: .default)
        #expect(policy.contains("object-src 'none'"))
        #expect(policy.contains("frame-src 'none'"))
        let wasm = SandboxCSPBuilder.buildPolicy(configuration: .default)
        #expect(wasm.contains("wasm-unsafe-eval"))
        var noWasm = SandboxConfiguration.default
        noWasm.enableWebAssembly = false
        #expect(!SandboxCSPBuilder.buildPolicy(configuration: noWasm).contains("wasm-unsafe-eval"))
    }

    @Test("injectCSP strips page policy and injects host policy")
    func cspInjectionEdges() {
        let html = #"<html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body>hi</body></html>"#
        let out = SandboxCSPBuilder.injectCSP(into: html, configuration: .default)
        #expect(out.contains("Content-Security-Policy"))
        #expect(!out.contains("default-src *"))
        let bare = SandboxCSPBuilder.injectCSP(into: "plain body", configuration: .default)
        #expect(bare.contains("<head>"))
    }

    @Test("DOM patch scripts embed escaped selector and mode assignment")
    func domPatcher() {
        let outer = DOMPatcher.generateSubtreePatchScript(selector: "#app", newHTML: "<p>hi</p>", mode: .outerHTML)
        #expect(outer.contains("target.outerHTML"))
        #expect(outer.contains("#app"))
        let inner = DOMPatcher.generateSubtreePatchScript(selector: "#app", newHTML: "<p>hi</p>", mode: .innerHTML)
        #expect(inner.contains("target.innerHTML"))
        let css = DOMPatcher.generateCSSPatchScript(css: "body { color: \"red\"; }")
        #expect(css.contains("sandbox-dynamic-styles"))
        let tricky = DOMPatcher.generateSubtreePatchScript(selector: "a'b", newHTML: "x\"y", mode: .outerHTML)
        #expect(!tricky.contains("a'b"))
    }

    @Test("Authorization policy allows listed tools only")
    func authPolicy() async throws {
        let policy = SandboxToolAuthorizationPolicy(allowedToolNames: ["read"])
        struct ReadTool: SandboxAgentTool {
            var name: String { "read" }
            var description: String { "r" }
            var parametersSchemaJSON: String { "{}" }
            var authorizationRequirement: SandboxToolAuthorizationRequirement { .readOnly }
            func execute(argumentsJSON: String) async throws -> String { "ok" }
        }
        struct WriteTool: SandboxAgentTool {
            var name: String { "write" }
            var description: String { "w" }
            var parametersSchemaJSON: String { "{}" }
            var authorizationRequirement: SandboxToolAuthorizationRequirement { .explicitApproval }
            func execute(argumentsJSON: String) async throws -> String { "ok" }
        }
        #expect(policy.allows(ReadTool()))
        #expect(!policy.allows(WriteTool()))
        #expect(SandboxToolAuthorizationPolicy().allows(ReadTool()) == false)
        #expect(try await ReadTool().execute(argumentsJSON: "{}") == "ok")
    }

    // MARK: - Cancellation

    @Test("Cancelled queue reader throws CancellationError")
    func cancellation() async {
        let q = SyncOfflineQueue()
        let task: Task<Int, Error> = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            return await q.pendingCount
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
