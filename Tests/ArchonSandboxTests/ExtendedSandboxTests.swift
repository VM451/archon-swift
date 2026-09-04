import Testing
import Foundation
import SwiftUI
@testable import ArchonSandbox

@Suite("Extended Sandbox Sync & Asset Chunking Tests")
struct ExtendedSandboxTests {

    @Test("SyncOfflineQueue enqueues, reschedules with backoff, and clears operations")
    func testSyncOfflineQueueLifecycle() async {
        let queue = SyncOfflineQueue()
        let wsID1 = UUID()
        let wsID2 = UUID()

        await queue.enqueue(workspaceID: wsID1)
        await queue.enqueue(workspaceID: wsID2)

        var count = await queue.pendingCount
        #expect(count == 2)

        let ready = await queue.readyOperations()
        #expect(ready.count == 2)

        guard let firstOp = ready.first else {
            Issue.record("Expected ready operations")
            return
        }

        // Mark failed with exponential backoff
        await queue.markFailed(id: firstOp.id, retryAfterSeconds: 10.0)
        let readyAfterFail = await queue.readyOperations()
        #expect(readyAfterFail.count == 1)

        // Mark completed
        if let remaining = readyAfterFail.first {
            await queue.markCompleted(id: remaining.id)
        }

        count = await queue.pendingCount
        #expect(count == 1)

        await queue.clear()
        count = await queue.pendingCount
        #expect(count == 0)
    }

    @Test("AssetChunkManager chunks and reassembles binary assets with checksum verification")
    func testAssetChunkManagerRoundtrip() throws {
        let sampleString = String(repeating: "ArchonSandbox WebAssembly Chunking Buffer ", count: 500)
        let sampleData = Data(sampleString.utf8)

        let chunks = AssetChunkManager.chunkData(sampleData, chunkSize: 1024)
        #expect(!chunks.isEmpty)

        let reassembled = try AssetChunkManager.reassembleChunks(chunks)
        #expect(reassembled == sampleData)
    }

    @Test("SandboxEvent cases and summary formatting")
    func testSandboxEventSummaries() {
        let logEvent = SandboxEvent.consoleLog(level: .warning, message: "Deprecation warning", timestamp: Date())
        #expect(logEvent.summary.contains("Deprecation warning"))

        let errorEvent = SandboxEvent.uncaughtError(message: "Null pointer exception", stackTrace: "at main.js:42")
        #expect(errorEvent.summary.contains("Null pointer exception"))

        let toolEvent = SandboxEvent.toolCall(id: "call-1", toolName: "fetch_data", argumentsJSON: "{}")
        #expect(toolEvent.summary.contains("fetch_data"))

        let mutationEvent = SandboxEvent.domMutation(summary: "Added 2 nodes", targetSelector: "#root", timestamp: Date())
        #expect(mutationEvent.summary.contains("Added 2 nodes"))
    }

    @Test("SandboxViewController manages logs and entry point configuration")
    @MainActor
    func testSandboxViewControllerState() {
        let ws = SandboxWorkspace.defaultTemplate(name: "Test Workspace")
        let controller = SandboxViewController(workspace: ws)

        #expect(controller.workspace.files.count == 1)
        #expect(controller.logs.isEmpty)

        controller.clearLogs()
        #expect(controller.logs.isEmpty)
    }
}
