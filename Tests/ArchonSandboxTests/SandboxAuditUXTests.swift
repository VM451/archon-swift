import Testing
import Foundation
@testable import ArchonSandbox

@Suite("Sandbox Audit UX Tests")
struct SandboxAuditUXTests {
    private func sampleRecords() -> [SandboxAuditRecord] {
        [
            SandboxAuditRecord(
                event: .capabilityDecision(permission: "storage", scope: "file:docs/a.txt", allowed: true, timestamp: Date()),
                outcome: .allowed,
                capability: .storage
            ),
            SandboxAuditRecord(
                event: .capabilityDecision(permission: "storage", scope: "file:docs/b.txt", allowed: false, timestamp: Date()),
                outcome: .denied,
                capability: .storage
            ),
            SandboxAuditRecord(
                event: .capabilityDecision(permission: "network", scope: "scheme:wss", allowed: false, timestamp: Date()),
                outcome: .denied,
                capability: .network
            ),
            SandboxAuditRecord(
                event: .uncaughtError(message: "WASM module rejected", stackTrace: nil),
                outcome: .error,
                capability: nil
            )
        ]
    }

    @Test("Default filter passes every record")
    func defaultFilterPassesAll() {
        let records = sampleRecords()
        #expect(SandboxAuditFilter.all.apply(to: records).count == 4)
    }

    @Test("Outcome filter selects matching records only")
    func outcomeFilter() {
        let records = sampleRecords()
        #expect(SandboxAuditFilter(outcome: .denied).apply(to: records).count == 2)
        #expect(SandboxAuditFilter(outcome: .allowed).apply(to: records).count == 1)
        #expect(SandboxAuditFilter(outcome: .error).apply(to: records).count == 1)
    }

    @Test("Capability filter selects matching records only")
    func capabilityFilter() {
        let records = sampleRecords()
        let storage = SandboxAuditFilter(capability: .storage).apply(to: records)
        #expect(storage.count == 2)
        #expect(storage.allSatisfy { $0.capability == .storage })
        #expect(SandboxAuditFilter(capability: .network).apply(to: records).count == 1)
        // Records without a capability never match a capability filter.
        #expect(SandboxAuditFilter(capability: .camera).apply(to: records).isEmpty)
    }

    @Test("Combined outcome and capability filters intersect")
    func combinedFilter() {
        let records = sampleRecords()
        let filtered = SandboxAuditFilter(outcome: .denied, capability: .storage).apply(to: records)
        #expect(filtered.count == 1)
        #expect(filtered.first?.outcome == .denied)
        #expect(filtered.first?.capability == .storage)
        #expect(SandboxAuditFilter(outcome: .allowed, capability: .network).apply(to: records).isEmpty)
    }

    @Test("Audit record summaries stay human-readable")
    func recordSummaries() {
        let records = sampleRecords()
        #expect(records[0].event.summary.contains("allowed"))
        #expect(records[1].event.summary.contains("denied"))
        #expect(records[3].event.summary.contains("WASM"))
    }
}
