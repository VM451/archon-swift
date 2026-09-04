import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Offline Queue & CloudKit Persistence Tests")
struct CloudKitSyncTests {
    
    @Test("Offline queue backoff and scheduling")
    func testOfflineQueue() async {
        let queue = SyncOfflineQueue()
        let id = UUID()
        
        await queue.enqueue(workspaceID: id)
        var count = await queue.pendingCount
        #expect(count == 1)
        
        let ready = await queue.readyOperations()
        #expect(ready.count == 1)
        
        // Mark failed with retry delay
        if let op = ready.first {
            await queue.markFailed(id: op.id, retryAfterSeconds: 300)
        }
        
        let readyAfterFail = await queue.readyOperations()
        #expect(readyAfterFail.isEmpty)
        
        await queue.clear()
        count = await queue.pendingCount
        #expect(count == 0)
    }
}
