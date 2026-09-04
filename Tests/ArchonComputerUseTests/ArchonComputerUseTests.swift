import Testing
import ArchonComputerUse

private struct MockObservationProvider: ComputerUseObservationProvider {
    let snapshot: SemanticSnapshot

    func captureSnapshot() async throws -> SemanticSnapshot { snapshot }
}

private struct AllowAllComputerUsePolicy: ComputerUsePermissionPolicy {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        _ = (risk, action)
        return true
    }
}

private actor ActionGate {
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<SemanticActionResult, Never>?
    private var isReady = false

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func waitForRelease() async -> SemanticActionResult {
        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func release(_ result: SemanticActionResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

struct ArchonComputerUseTests {
    @Test("Semantic actions can require an element from a fresh observation")
    func observesTargetBeforeExecution() async throws {
        let observation = MockObservationProvider(snapshot: SemanticSnapshot(
            screenID: "home",
            elements: [SemanticElement(id: "compose", role: "button", label: "Compose")]
        ))
        let controller = ComputerUseController(
            observationProvider: observation,
            permissionPolicy: AllowAllComputerUsePolicy()
        )
        await controller.register(SemanticAction(
            id: "compose.open",
            description: "Open composer",
            risk: .navigate,
            targetElementID: "compose"
        ) {
            SemanticActionResult(actionID: "compose.open", succeeded: true)
        })

        _ = try await controller.execute(actionID: "compose.open")

        #expect(await controller.lastSnapshot?.screenID == "home")
    }

    @Test("Semantic action executes through the registered host-app action")
    func executesSemanticAction() async throws {
        let controller = ComputerUseController(permissionPolicy: ReadOnlyComputerUsePolicy())
        await controller.register(SemanticAction(id: "screen.open", description: "Open screen", risk: .navigate) {
            SemanticActionResult(actionID: "screen.open", succeeded: true, message: "opened")
        })

        let result = try await controller.start(actionID: "screen.open")

        #expect(result.succeeded)
        #expect(result.actionID == "screen.open")
        #expect(await controller.state == .idle)
    }

    @Test("Semantic action can enforce a host-defined postcondition")
    func verifiesPostActionState() async throws {
        let observation = MockObservationProvider(snapshot: SemanticSnapshot(
            screenID: "detail",
            elements: [SemanticElement(id: "saved", role: "status", label: "Saved")]
        ))
        let controller = ComputerUseController(
            observationProvider: observation,
            permissionPolicy: AllowAllComputerUsePolicy()
        )
        await controller.register(SemanticAction(
            id: "record.save",
            description: "Save record",
            risk: .modify,
            verify: { result, snapshot in
                result.message == "saved" &&
                    snapshot?.elements.contains(where: { $0.id == "saved" }) == true
            }
        ) {
            SemanticActionResult(actionID: "record.save", succeeded: true, message: "saved")
        })

        let result = try await controller.execute(actionID: "record.save")

        #expect(result.succeeded)
    }

    @Test("Read-only policy rejects destructive semantic actions")
    func rejectsDestructiveAction() async throws {
        let controller = ComputerUseController(permissionPolicy: ReadOnlyComputerUsePolicy())
        await controller.register(SemanticAction(id: "record.delete", description: "Delete record", risk: .destructive) {
            SemanticActionResult(actionID: "record.delete", succeeded: true)
        })

        do {
            _ = try await controller.execute(actionID: "record.delete")
            Issue.record("Expected destructive action to be denied.")
        } catch {
            #expect(error.localizedDescription.contains("denied"))
        }
    }

    @Test("Stop prevents a non-cooperative host action from reporting success")
    func stopInvalidatesLateActionResult() async throws {
        let gate = ActionGate()
        let controller = ComputerUseController(permissionPolicy: AllowAllComputerUsePolicy())
        await controller.register(SemanticAction(
            id: "record.save",
            description: "Save record",
            risk: .modify
        ) {
            // Deliberately ignore task cancellation. The controller must
            // still reject the late result after stop() has invalidated it.
            await gate.waitForRelease()
        })

        let execution = Task {
            try await controller.execute(actionID: "record.save")
        }
        await gate.waitUntilReady()
        await controller.stop()
        await gate.release(SemanticActionResult(actionID: "record.save", succeeded: true))

        do {
            _ = try await execution.value
            Issue.record("A stopped action must not return a successful result.")
        } catch let error as ComputerUseError {
            #expect(error == .actionCancelled("record.save"))
        }
        #expect(await controller.state == .stopped)
    }
}
