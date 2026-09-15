import Testing
import Foundation
import ArchonComputerUse

private struct AllowAll: ComputerUsePermissionPolicy {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool { true }
}

private struct FixedSnapshot: ComputerUseObservationProvider {
    let snapshot: SemanticSnapshot
    func captureSnapshot() async throws -> SemanticSnapshot { snapshot }
}

@Suite("ComputerUse Execution Limits Tests")
struct ComputerUseLimitsTests {
    @Test("Invalid action IDs are refused at registration")
    func refusesInvalidIDs() async {
        let controller = ComputerUseController(permissionPolicy: AllowAll())
        let refused = await controller.register(SemanticAction(id: "../escape", description: "x", risk: .read) {
            SemanticActionResult(actionID: "../escape", succeeded: true)
        })
        #expect(!refused)
        #expect(await controller.isRegistered(id: "../escape") == false)
        let empty = await controller.register(SemanticAction(id: "", description: "x", risk: .read) {
            SemanticActionResult(actionID: "", succeeded: true)
        })
        #expect(!empty)
    }

    @Test("Session action budget fails closed")
    func sessionBudget() async throws {
        let controller = ComputerUseController(
            permissionPolicy: AllowAll(),
            limits: ComputerUseExecutionLimits(maximumActionsPerSession: 1, maximumActionIDLength: 128, maximumElementsPerSnapshot: 1_000)
        )
        await controller.register(SemanticAction(id: "a.one", description: "one", risk: .read) {
            SemanticActionResult(actionID: "a.one", succeeded: true)
        })
        await controller.register(SemanticAction(id: "a.two", description: "two", risk: .read) {
            SemanticActionResult(actionID: "a.two", succeeded: true)
        })
        _ = try await controller.execute(actionID: "a.one")
        do {
            _ = try await controller.execute(actionID: "a.two")
            Issue.record("Second action must exceed the session budget.")
        } catch let error as ComputerUseError {
            #expect(error == .limitsExceeded("a.two"))
        }
    }

    @Test("Oversized snapshots are rejected")
    func oversizedSnapshot() async {
        let elements = (0..<5).map { SemanticElement(id: "e\($0)", role: "cell", label: "c") }
        let controller = ComputerUseController(
            observationProvider: FixedSnapshot(snapshot: SemanticSnapshot(screenID: "grid", elements: elements)),
            permissionPolicy: AllowAll(),
            limits: ComputerUseExecutionLimits(maximumActionsPerSession: 10, maximumActionIDLength: 128, maximumElementsPerSnapshot: 2)
        )
        do {
            _ = try await controller.observe()
            Issue.record("Oversized snapshot must fail closed.")
        } catch let error as ComputerUseError {
            #expect(error == .limitsExceeded("snapshot.grid"))
        } catch {
            Issue.record("Unexpected error type: \(error).")
        }
    }
}
