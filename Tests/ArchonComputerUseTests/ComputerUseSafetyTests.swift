import Foundation
import Testing
import ArchonComputerUse
import ArchonCore

private struct AllowAllPolicy: ComputerUsePermissionPolicy {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        _ = (risk, action)
        return true
    }
}

private struct ExpiringApprovalPolicy: ComputerUsePermissionPolicy {
    let lifetime: TimeInterval

    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        _ = (risk, action)
        return true
    }

    func approval(for risk: ComputerUseRisk, action: SemanticAction) async -> ComputerUseApproval? {
        _ = risk
        let issued = Date()
        return ComputerUseApproval(actionID: action.id, issuedAt: issued, expiresAt: issued.addingTimeInterval(lifetime))
    }
}

private struct FallbackOptInPolicy: ComputerUsePermissionPolicy {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        _ = (risk, action)
        return true
    }

    func allowsFallback(_ request: ComputerUseFallbackRequest) async -> Bool {
        request.uncertainty <= 0.5
    }
}

private actor RecordingAuditSink: ArchonAuditSink {
    private(set) var events: [ArchonAuditEvent] = []

    func record(_ event: ArchonAuditEvent) {
        events.append(event)
    }
}

private actor ReleaseGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func enterAndWait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite("Computer Use Safety Tests")
struct ComputerUseSafetyTests {
    @Test("Stopped sessions refuse fresh executions until resumed")
    func testStoppedRefusesFreshExecution() async throws {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        let action = SemanticAction(id: "tap", description: "Tap", risk: .navigate) {
            SemanticActionResult(actionID: "tap", succeeded: true)
        }
        #expect(await controller.register(action))
        await controller.stop()

        await #expect(throws: ComputerUseError.stopped) {
            try await controller.execute(actionID: "tap")
        }

        let resumed = try await controller.resume(actionID: "tap")
        #expect(resumed.succeeded)
    }

    @Test("A second execution is rejected while one runs")
    func testConcurrentExecutionRejected() async throws {
        let gate = ReleaseGate()
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        let action = SemanticAction(id: "slow", description: "Slow", risk: .navigate) {
            await gate.enterAndWait()
            return SemanticActionResult(actionID: "slow", succeeded: true)
        }
        #expect(await controller.register(action))

        let first = Task { try await controller.execute(actionID: "slow") }
        await gate.waitUntilEntered()
        await #expect(throws: ComputerUseError.actionCancelled("slow")) {
            try await controller.execute(actionID: "slow")
        }
        await gate.release()
        let result = try await first.value
        #expect(result.succeeded)
    }

    @Test("Approval expiring mid-flight fails the action closed")
    func testApprovalExpiryMidFlight() async throws {
        let gate = ReleaseGate()
        let controller = ComputerUseController(
            permissionPolicy: ExpiringApprovalPolicy(lifetime: 0.05)
        )
        let action = SemanticAction(id: "slow", description: "Slow", risk: .modify) {
            await gate.enterAndWait()
            return SemanticActionResult(actionID: "slow", succeeded: true)
        }
        #expect(await controller.register(action))

        let outcome = Task { try await controller.execute(actionID: "slow") }
        await gate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(150))
        await gate.release()
        await #expect(throws: ComputerUseError.approvalRequired("slow")) {
            try await outcome.value
        }
    }

    @Test("Audit sink records denied and succeeded outcomes")
    func testAuditRecordsOutcomes() async throws {
        let sink = RecordingAuditSink()
        let controller = ComputerUseController(
            permissionPolicy: ReadOnlyComputerUsePolicy(),
            auditSink: sink
        )
        let reader = SemanticAction(id: "read", description: "Read", risk: .read) {
            SemanticActionResult(actionID: "read", succeeded: true)
        }
        let writer = SemanticAction(id: "write", description: "Write", risk: .destructive) {
            SemanticActionResult(actionID: "write", succeeded: true)
        }
        #expect(await controller.register(reader))
        #expect(await controller.register(writer))

        _ = try await controller.execute(actionID: "read")
        await #expect(throws: ComputerUseError.permissionDenied("write")) {
            try await controller.execute(actionID: "write")
        }

        let events = await sink.events
        #expect(events.count == 2)
        #expect(events.contains { $0.action == "read" && $0.outcome == "succeeded" && $0.metadata["risk"] == "read" })
        #expect(events.contains { $0.action == "write" && $0.outcome == "denied" && $0.metadata["risk"] == "destructive" })
    }

    @Test("Visual fallback is denied by default and audited")
    func testFallbackDeniedByDefault() async throws {
        let sink = RecordingAuditSink()
        let controller = ComputerUseController(
            permissionPolicy: ReadOnlyComputerUsePolicy(),
            auditSink: sink
        )
        await #expect(throws: ComputerUseError.permissionDenied("fallback.login")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "login",
                reason: "No semantic surface on this screen",
                uncertainty: 0.7
            ))
        }
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.outcome == "denied")
    }

    @Test("Opt-in policy approves bounded fallbacks and audits uncertainty")
    func testFallbackOptInApprovesBoundedRequests() async throws {
        let sink = RecordingAuditSink()
        let controller = ComputerUseController(
            permissionPolicy: FallbackOptInPolicy(),
            auditSink: sink
        )
        try await controller.requestFallback(ComputerUseFallbackRequest(
            actionID: "login",
            reason: "No semantic surface on this screen",
            uncertainty: 0.3,
            maximumAttempts: 2
        ))
        await #expect(throws: ComputerUseError.permissionDenied("fallback.login")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "login",
                reason: "Too uncertain",
                uncertainty: 0.9
            ))
        }
        let events = await sink.events
        #expect(events.count == 2)
        let approved = try #require(events.first { $0.outcome == "approved" })
        #expect(approved.metadata["uncertainty"] == String(0.3))
        #expect(approved.metadata["maximumAttempts"] == "2")
    }

    @Test("Fallback bounds reject bad IDs, uncertainty, and attempts")
    func testFallbackBoundsRejectInvalidRequests() async {
        let controller = ComputerUseController(permissionPolicy: FallbackOptInPolicy())
        await #expect(throws: ComputerUseError.limitsExceeded("bad id!")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "bad id!",
                reason: "x",
                uncertainty: 0.1
            ))
        }
        await #expect(throws: ComputerUseError.limitsExceeded("login")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "login",
                reason: "x",
                uncertainty: 1.5
            ))
        }
        await #expect(throws: ComputerUseError.limitsExceeded("login")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "login",
                reason: "x",
                uncertainty: .nan
            ))
        }
        await #expect(throws: ComputerUseError.limitsExceeded("login")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "login",
                reason: "x",
                uncertainty: 0.1,
                maximumAttempts: 0
            ))
        }
    }
}
