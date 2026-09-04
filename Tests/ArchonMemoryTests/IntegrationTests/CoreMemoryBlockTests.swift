import Testing
import Foundation
@testable import ArchonMemory

@Suite("Core Memory Working Block Integration Tests")
struct CoreMemoryBlockTests {
    
    @Test("Working core memory block set and get operations")
    func testCoreMemorySetAndGet() async throws {
        let store = try LocalVectorStore(inMemory: true)
        
        try await store.setCoreMemoryBlock(key: "human_name", value: "Alex")
        try await store.setCoreMemoryBlock(key: "persona", value: "Socratic Coding Tutor")

        let blocks = try await store.getCoreMemoryBlock()
        #expect(blocks["human_name"] == "Alex")
        #expect(blocks["persona"] == "Socratic Coding Tutor")
    }

    @Test("Core memory blocks with the same key remain isolated by user")
    func testCoreMemoryUserIsolation() async throws {
        let store = try LocalVectorStore(inMemory: true)
        try await store.setCoreMemoryBlock(key: "persona", value: "User A", userId: "a")
        try await store.setCoreMemoryBlock(key: "persona", value: "User B", userId: "b")

        #expect(try await store.getCoreMemoryBlock(userId: "a")["persona"] == "User A")
        #expect(try await store.getCoreMemoryBlock(userId: "b")["persona"] == "User B")
    }
}
