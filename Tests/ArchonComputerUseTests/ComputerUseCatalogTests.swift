import Foundation
import Testing
import ArchonComputerUse
import ArchonCore

private struct CatalogAllowAll: ComputerUsePermissionPolicy {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool { true }
}

private struct CatalogExpiringApprovals: ComputerUsePermissionPolicy {
    let lifetime: TimeInterval

    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool { true }

    func approval(for risk: ComputerUseRisk, action: SemanticAction) async -> ComputerUseApproval? {
        _ = risk
        let issued = Date()
        return ComputerUseApproval(actionID: action.id, issuedAt: issued, expiresAt: issued.addingTimeInterval(lifetime))
    }
}

private actor CatalogAuditSink: ArchonAuditSink {
    private(set) var events: [ArchonAuditEvent] = []

    func record(_ event: ArchonAuditEvent) {
        events.append(event)
    }
}

private struct CatalogFixedSnapshot: ComputerUseObservationProvider {
    let snapshot: SemanticSnapshot
    func captureSnapshot() async throws -> SemanticSnapshot { snapshot }
}

private actor CatalogReleaseGate {
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

private struct CatalogTestBridge: ComputerUseAppIntentBridge {
    func descriptor(for intentID: String) -> SemanticActionDescriptor? {
        switch intentID {
        case "OpenInboxIntent":
            return SemanticActionDescriptor(
                id: "inbox.open",
                description: "Open the inbox",
                risk: .navigate
            )
        case "ArchiveMessageIntent":
            return SemanticActionDescriptor(
                id: "inbox.archive",
                description: "Archive the selected message",
                risk: .modify,
                targetRole: "button",
                requiresApproval: true,
                postconditionID: "message-archived"
            )
        default:
            return nil
        }
    }
}

@Suite("Computer Use Catalog Tests")
struct ComputerUseCatalogTests {
    @Test("Descriptor IDs follow the controller allowlist")
    func descriptorIDAllowlist() async {
        let controller = ComputerUseController(permissionPolicy: CatalogAllowAll())
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(id: "inbox.open", description: "Open", risk: .read),
            SemanticActionDescriptor(id: "../escape", description: "Nope", risk: .read),
            SemanticActionDescriptor(id: "", description: "Empty", risk: .read)
        ])
        let outcomes = await catalog.register(on: controller) { descriptor in
            SemanticActionResult(actionID: descriptor.id, succeeded: true)
        }
        #expect(outcomes["inbox.open"] == true)
        #expect(outcomes["../escape"] == false)
        #expect(outcomes[""] == false)
        #expect(await controller.isRegistered(id: "inbox.open"))
        #expect(await controller.isRegistered(id: "../escape") == false)
    }

    @Test("Modify and above require a postcondition")
    func modifyRequiresPostcondition() async {
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .read).requiresPostcondition == false)
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .navigate).requiresPostcondition == false)
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .modify).requiresPostcondition)
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .sensitive).requiresPostcondition)
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .destructive).requiresPostcondition)
        #expect(SemanticActionDescriptor(id: "a", description: "x", risk: .external).requiresPostcondition)

        let controller = ComputerUseController(permissionPolicy: CatalogAllowAll())
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(id: "doc.edit", description: "Edit", risk: .modify),
            SemanticActionDescriptor(
                id: "doc.save", description: "Save", risk: .modify,
                postconditionID: "saved"
            )
        ])
        // No verifiers supplied: both modify descriptors are refused.
        let refused = await catalog.register(on: controller) { descriptor in
            SemanticActionResult(actionID: descriptor.id, succeeded: true)
        }
        #expect(refused["doc.edit"] == false)
        #expect(refused["doc.save"] == false)

        // With a matching verifier, the described postcondition registers.
        let accepted = await catalog.register(
            on: controller,
            execute: { descriptor in SemanticActionResult(actionID: descriptor.id, succeeded: true) },
            verifiers: ["saved": ComputerUsePostcondition(id: "saved") { _, _ in true }]
        )
        #expect(accepted["doc.edit"] == false)
        #expect(accepted["doc.save"] == true)
    }

    @Test("Failing postconditions fail execution closed")
    func postconditionEnforced() async throws {
        let controller = ComputerUseController(permissionPolicy: CatalogAllowAll())
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(
                id: "doc.save", description: "Save", risk: .modify,
                postconditionID: "saved"
            )
        ])
        _ = await catalog.register(
            on: controller,
            execute: { descriptor in SemanticActionResult(actionID: descriptor.id, succeeded: true) },
            verifiers: ["saved": ComputerUsePostcondition(id: "saved") { _, _ in false }]
        )
        await #expect(throws: ComputerUseError.verificationFailed("doc.save")) {
            try await controller.execute(actionID: "doc.save")
        }
    }

    @Test("Catalog actions honor approval expiry mid-flight")
    func approvalExpiryMidFlight() async throws {
        let gate = CatalogReleaseGate()
        let controller = ComputerUseController(
            permissionPolicy: CatalogExpiringApprovals(lifetime: 0.05)
        )
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(
                id: "doc.save", description: "Save", risk: .modify,
                requiresApproval: true,
                postconditionID: "saved"
            )
        ])
        _ = await catalog.register(
            on: controller,
            execute: { descriptor in
                await gate.enterAndWait()
                return SemanticActionResult(actionID: descriptor.id, succeeded: true)
            },
            verifiers: ["saved": ComputerUsePostcondition(id: "saved") { _, _ in true }]
        )

        let outcome = Task { try await controller.execute(actionID: "doc.save") }
        await gate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(150))
        await gate.release()
        await #expect(throws: ComputerUseError.approvalRequired("doc.save")) {
            try await outcome.value
        }
    }

    @Test("Stale target roles fail closed; present roles execute")
    func staleTargetFailsClosed() async throws {
        let withoutButton = SemanticSnapshot(screenID: "inbox", elements: [
            SemanticElement(id: "title", role: "heading", label: "Inbox")
        ])
        let staleController = ComputerUseController(
            observationProvider: CatalogFixedSnapshot(snapshot: withoutButton),
            permissionPolicy: CatalogAllowAll()
        )
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(
                id: "inbox.archive", description: "Archive", risk: .navigate,
                targetRole: "button"
            )
        ])
        _ = await catalog.register(on: staleController) { descriptor in
            SemanticActionResult(actionID: descriptor.id, succeeded: true)
        }
        _ = try await staleController.observe()
        await #expect(throws: ComputerUseError.staleObservation("inbox.archive")) {
            try await staleController.execute(actionID: "inbox.archive")
        }

        let withButton = SemanticSnapshot(screenID: "inbox", elements: [
            SemanticElement(id: "archive", role: "button", label: "Archive")
        ])
        let freshController = ComputerUseController(
            observationProvider: CatalogFixedSnapshot(snapshot: withButton),
            permissionPolicy: CatalogAllowAll()
        )
        _ = await catalog.register(on: freshController) { descriptor in
            SemanticActionResult(actionID: descriptor.id, succeeded: true)
        }
        _ = try await freshController.observe()
        let result = try await freshController.execute(actionID: "inbox.archive")
        #expect(result.succeeded)
    }

    @Test("App Intent bridge maps known intents and skips unknown ones")
    func appIntentBridgeMapping() async throws {
        let catalog = ComputerUseCatalog(
            bridging: CatalogTestBridge(),
            intentIDs: ["OpenInboxIntent", "ArchiveMessageIntent", "UnknownIntent"]
        )
        #expect(catalog.actions.map(\.id) == ["inbox.open", "inbox.archive"])

        let controller = ComputerUseController(permissionPolicy: CatalogAllowAll())
        let outcomes = await catalog.register(
            on: controller,
            execute: { descriptor in SemanticActionResult(actionID: descriptor.id, succeeded: true) },
            verifiers: ["message-archived": ComputerUsePostcondition(id: "message-archived") { _, _ in true }]
        )
        #expect(outcomes["inbox.open"] == true)
        // The archive descriptor carries a target role but no observation
        // provider exists, so its precondition fails closed as stale.
        let opened = try await controller.execute(actionID: "inbox.open")
        #expect(opened.succeeded)
        await #expect(throws: ComputerUseError.staleObservation("inbox.archive")) {
            try await controller.execute(actionID: "inbox.archive")
        }
    }

    @Test("Throwing registration reports the refused descriptor")
    func registerOrThrowReportsInvalid() async {
        let controller = ComputerUseController(permissionPolicy: CatalogAllowAll())
        let catalog = ComputerUseCatalog(actions: [
            SemanticActionDescriptor(id: "doc.edit", description: "Edit", risk: .modify)
        ])
        await #expect(throws: ComputerUseError.invalidDescriptor("doc.edit")) {
            try await catalog.registerOrThrow(on: controller) { descriptor in
                SemanticActionResult(actionID: descriptor.id, succeeded: true)
            }
        }
    }

    @Test("Visual fallback stays default-deny with catalog controllers")
    func fallbackStillDefaultDeny() async throws {
        let sink = CatalogAuditSink()
        let controller = ComputerUseController(
            permissionPolicy: ReadOnlyComputerUsePolicy(),
            auditSink: sink
        )
        await #expect(throws: ComputerUseError.permissionDenied("fallback.inbox.open")) {
            try await controller.requestFallback(ComputerUseFallbackRequest(
                actionID: "inbox.open",
                reason: "No semantic surface on this screen",
                uncertainty: 0.7
            ))
        }
        #expect(await sink.events.count == 1)
        #expect(await sink.events.first?.outcome == "denied")
    }
}
