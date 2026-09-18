import Testing
import Foundation
@testable import ArchonSandbox

private actor PolicyCallGate {
    private var arrived = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() {
        arrived += 1
        if released { return }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor PolicyScriptRecorder {
    private(set) var scripts: [String] = []

    func record(_ script: String) {
        scripts.append(script)
    }
}

@Suite("Sandbox Capability Policy Tests")
struct SandboxCapabilityPolicyTests {
    private static let wasmBytes = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

    private func wasmWorkspace() -> SandboxWorkspace {
        SandboxWorkspace(
            name: "wasm",
            binaryFiles: ["assets/model.wasm": Self.wasmBytes]
        )
    }

    @Test("Expired grants deny while valid grants allow")
    func expiredGrantDenied() {
        let expired = SandboxCapabilityGrant(
            permission: .network,
            scope: .session,
            expiresAt: Date().addingTimeInterval(-60)
        )
        let fresh = SandboxCapabilityGrant(
            permission: .network,
            scope: .session,
            expiresAt: Date().addingTimeInterval(60)
        )
        let expiredConfig = SandboxConfiguration(
            allowedPermissions: [.network],
            capabilityGrants: [expired]
        )
        let freshConfig = SandboxConfiguration(
            allowedPermissions: [.network],
            capabilityGrants: [fresh]
        )
        #expect(!expired.isValid())
        #expect(fresh.isValid())
        #expect(!expiredConfig.allows(.network, scope: .session))
        #expect(freshConfig.allows(.network, scope: .session))
    }

    @Test("File-scoped grants allow only the granted file")
    func fileScopedGrant() {
        let configuration = SandboxConfiguration(
            allowedPermissions: [.storage],
            capabilityGrants: [SandboxCapabilityGrant(
                permission: .storage,
                scope: .workspaceFile("docs/a.txt")
            )]
        )
        #expect(configuration.allows(.storage, scope: .workspaceFile("docs/a.txt")))
        #expect(configuration.allows(.storage, scope: .workspaceFile("/docs/a.txt")))
        #expect(!configuration.allows(.storage, scope: .workspaceFile("docs/b.txt")))
        #expect(!configuration.allows(.storage, scope: .session))
    }

    @Test("Scheme-scoped grants allow only the granted scheme")
    func schemeScopedGrant() {
        let configuration = SandboxConfiguration(
            allowedPermissions: [.network],
            capabilityGrants: [SandboxCapabilityGrant(
                permission: .network,
                scope: .scheme("https")
            )]
        )
        #expect(configuration.allows(.network, scope: .scheme("https")))
        #expect(configuration.allows(.network, scope: .scheme("HTTPS")))
        #expect(!configuration.allows(.network, scope: .scheme("wss")))
        #expect(!configuration.allows(.network, scope: .session))
    }

    @Test("Grants never widen the base permission policy")
    func grantsRequireBasePermission() {
        let configuration = SandboxConfiguration(
            allowedPermissions: [],
            capabilityGrants: [SandboxCapabilityGrant(
                permission: .storage,
                scope: .workspaceFile("docs/a.txt")
            )]
        )
        #expect(!configuration.allows(.storage, scope: .workspaceFile("docs/a.txt")))

        // Without any grants, resource scopes fail closed even when the base
        // policy allows the permission; session scope honors the base policy.
        let grantless = SandboxConfiguration(allowedPermissions: [.storage])
        #expect(!grantless.allows(.storage, scope: .workspaceFile("docs/a.txt")))
        #expect(grantless.allows(.storage, scope: .session))
    }

    @Test("Capability checks emit audit records for allow and deny")
    func auditRecordsEmitted() async {
        let engine = SandboxEngine(
            workspace: SandboxWorkspace(name: "audit"),
            configuration: SandboxConfiguration(
                allowedPermissions: [.storage],
                capabilityGrants: [SandboxCapabilityGrant(
                    permission: .storage,
                    scope: .workspaceFile("docs/a.txt")
                )]
            )
        )
        #expect(await engine.checkCapability(.storage, scope: .workspaceFile("docs/a.txt")))
        #expect(await engine.checkCapability(.storage, scope: .workspaceFile("docs/b.txt")) == false)

        let records = await engine.auditRecords()
        #expect(records.count == 2)
        #expect(records.map(\.outcome) == [.allowed, .denied])
        #expect(records.allSatisfy { $0.capability == .storage })
        #expect(records.allSatisfy {
            if case .capabilityDecision = $0.event { return true }
            return false
        })
    }

    @Test("Disabling WebAssembly strips wasm-unsafe-eval from the CSP")
    func wasmFlagStripsCSPToken() {
        let enabled = SandboxConfiguration(enableWebAssembly: true)
        let disabled = SandboxConfiguration(enableWebAssembly: false)
        #expect(SandboxCSPBuilder.buildPolicy(configuration: enabled).contains("'wasm-unsafe-eval'"))
        #expect(!SandboxCSPBuilder.buildPolicy(configuration: disabled).contains("'wasm-unsafe-eval'"))
        #expect(!SandboxCSPBuilder.buildPolicy(configuration: disabled).contains("wasm"))
    }

    @Test("Valid workspace WASM loads through the page bridge")
    func validWasmLoads() async throws {
        let engine = SandboxEngine(workspace: wasmWorkspace())
        let recorder = PolicyScriptRecorder()
        await engine.bindEvaluator { script in
            await recorder.record(script)
            return "wasm-loaded"
        }
        try await engine.loadWasmModule(SandboxWasmModule(path: "assets/model.wasm"))

        let scripts = await recorder.scripts
        #expect(scripts.count == 1)
        // The path is embedded as a JSON-escaped JS string literal, so `/`
        // appears as `\/`; assert on the unescaped segments instead.
        #expect(scripts.first?.contains("assets") == true)
        #expect(scripts.first?.contains("model.wasm") == true)
        #expect(scripts.first?.contains("sandbox:") == true)
        #expect(scripts.first?.contains("WebAssembly") == true)

        let records = await engine.auditRecords()
        #expect(records.last?.outcome == .allowed)
    }

    @Test("Oversize WASM modules are rejected with an error audit")
    func oversizeWasmRejected() async throws {
        let engine = SandboxEngine(workspace: wasmWorkspace())
        await engine.bindEvaluator { script in script }
        do {
            try await engine.loadWasmModule(SandboxWasmModule(
                path: "assets/model.wasm",
                maxBytes: 4
            ))
            Issue.record("Expected the oversize WASM module to be rejected.")
        } catch let error as SandboxWasmError {
            #expect(error == .moduleTooLarge(path: "assets/model.wasm", size: 8, maximum: 4))
        }
        let records = await engine.auditRecords()
        #expect(records.last?.outcome == .error)
    }

    @Test("WASM loading fails closed when disabled or misaddressed")
    func wasmFailsClosed() async {
        let disabledEngine = SandboxEngine(
            workspace: wasmWorkspace(),
            configuration: SandboxConfiguration(enableWebAssembly: false)
        )
        await disabledEngine.bindEvaluator { script in script }
        await #expect(throws: SandboxWasmError.webAssemblyDisabled) {
            try await disabledEngine.loadWasmModule(SandboxWasmModule(path: "assets/model.wasm"))
        }

        let engine = SandboxEngine(workspace: wasmWorkspace())
        await engine.bindEvaluator { script in script }
        await #expect(throws: SandboxWasmError.invalidPath("../escape.wasm")) {
            try await engine.loadWasmModule(SandboxWasmModule(path: "../escape.wasm"))
        }
        await #expect(throws: SandboxWasmError.moduleNotFound("assets/missing.wasm")) {
            try await engine.loadWasmModule(SandboxWasmModule(path: "assets/missing.wasm"))
        }
    }

    @Test("Bridge size and workspace quota bounds still hold")
    func boundsPreserved() async {
        let engine = SandboxEngine(workspace: SandboxWorkspace(name: "bound"))
        let sizing = Task {
            var events: [SandboxEvent] = []
            for await event in engine.eventStream {
                events.append(event)
                if events.count >= 2 { break }
            }
            return events
        }
        await engine.handleIncomingJSON(String(repeating: "x", count: 256 * 1024 + 1))
        let sizeEvents = await sizing.value
        #expect(sizeEvents.contains {
            if case .uncaughtError(let message, _) = $0 {
                return message.contains("exceeds the configured size limit")
            }
            return false
        })

        let quotaEngine = SandboxEngine(
            workspace: SandboxWorkspace(name: "quota", files: []),
            configuration: SandboxConfiguration(maxMemoryMB: 1)
        )
        let quota = Task {
            var events: [SandboxEvent] = []
            for await event in quotaEngine.eventStream {
                events.append(event)
                if events.count >= 2 { break }
            }
            return events
        }
        await quotaEngine.updateFile(SandboxFile(path: "exact.bin", text: String(repeating: "a", count: 1_048_576)))
        await quotaEngine.updateFile(SandboxFile(path: "overflow.bin", text: String(repeating: "b", count: 1_048_577)))
        let quotaEvents = await quota.value
        let workspace = await quotaEngine.getWorkspace()
        #expect(workspace.file(at: "exact.bin") != nil)
        #expect(workspace.file(at: "overflow.bin") == nil)
        #expect(quotaEvents.contains {
            if case .uncaughtError(let message, _) = $0 {
                return message.contains("quota exceeded")
            }
            return false
        })
    }

    @Test("Tool-call concurrency cap still holds at 32")
    func concurrencyCapPreserved() async {
        let gate = PolicyCallGate()
        var configuration = SandboxConfiguration()
        configuration.allowedSandboxToolNames = ["gate"]
        let engine = SandboxEngine(
            workspace: SandboxWorkspace(name: "cap"),
            configuration: configuration
        )
        await engine.registerTool(ClosureAgentTool(name: "gate", description: "blocking gate") { _ in
            await gate.arriveAndWait()
            await gate.waitForRelease()
            return "{}"
        })

        let collector = Task {
            var events: [SandboxEvent] = []
            for await event in engine.eventStream {
                events.append(event)
                if events.count >= 34 { break }
            }
            return events
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<33 {
                group.addTask {
                    await engine.handleIncomingJSON(
                        #"{"type":"TOOL_CALL","id":"call-\#(index)","toolName":"gate","arguments":{}}"#
                    )
                }
            }
        }
        await gate.release()
        let events = await collector.value

        let toolCalls = events.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolCalls.count == 32)
        #expect(events.filter {
            if case .uncaughtError(let message, _) = $0 {
                return message.contains("concurrency limit exceeded")
            }
            return false
        }.count == 1)
    }
}
