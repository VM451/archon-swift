import Foundation
import Testing
@testable import ArchonMemory

/// Focused common + edge coverage for ArchonMemory value types that every
/// product surface depends on. Deterministic, no I/O, no network.
struct ArchonMemoryEdgeCasesTests {
    @Test func filterDefaultsExcludeDeleted() {
        let f = MemoryFilter()
        #expect(f.includeDeleted == false)
        #expect(f.userId == nil && f.agentId == nil && f.runId == nil)
        #expect(f.metadata == nil)
        #expect(f.activeAt != nil)
    }

    @Test func filterCodableRoundTrip() throws {
        let f = MemoryFilter(userId: "u", agentId: "a", runId: "r",
                             metadata: ["k": "v"], includeDeleted: true,
                             activeAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(MemoryFilter.self, from: data)
        #expect(back == f)
    }

    @Test func errorDescriptionsAreActionable() {
        let id = UUID()
        #expect(ArchonMemoryError.memoryNotFound(id).errorDescription?.contains(id.uuidString) == true)
        #expect(ArchonMemoryError.inputTooLarge(maxBytes: 10).errorDescription?.contains("10") == true)
        #expect(ArchonMemoryError.unsupportedDocumentFormat("exe").errorDescription?.contains("exe") == true)
        #expect(ArchonMemoryError.invalidConfiguration("bad").errorDescription?.contains("bad") == true)
        #expect(ArchonMemoryError.invalidSearchRequest("q").errorDescription?.contains("q") == true)
        #expect(ArchonMemoryError.invalidCompetitiveResearch("x").errorDescription?.contains("x") == true)
        #expect(ArchonMemoryError.documentLoadFailed("r").errorDescription?.contains("r") == true)
    }

    @Test func errorEquality() {
        #expect(ArchonMemoryError.inputTooLarge(maxBytes: 1) == .inputTooLarge(maxBytes: 1))
        #expect(ArchonMemoryError.inputTooLarge(maxBytes: 1) != .inputTooLarge(maxBytes: 2))
    }
}
