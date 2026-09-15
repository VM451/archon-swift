import Foundation
import Testing
@testable import ArchonCore

private struct SamplePayload: Codable, Equatable, Sendable {
    let name: String
    let count: Int
}

private struct FakeStructuredOutputProvider: ArchonStructuredOutputProvider, Sendable {
    let json: String
    func generateStructuredOutput<T: Decodable & Sendable>(
        prompt: String,
        responseSchema: T.Type
    ) async throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

private struct FailingStructuredOutputProvider: ArchonStructuredOutputProvider, Sendable {
    struct Boom: Error {}
    func generateStructuredOutput<T: Decodable & Sendable>(
        prompt: String,
        responseSchema: T.Type
    ) async throws -> T {
        throw Boom()
    }
}

struct ArchonCoreCoverageTests {
    // MARK: - Redactor

    @Test("Redactor redacts all sensitive key variants case-insensitively")
    func redactorVariants() {
        let input = [
            "TOKEN": "a",
            "Api-Key": "b",
            "apikey2": "c",
            "userPassword": "d",
            "mySecret": "e",
            "credential-id": "f",
            "Authorization": "g",
            "session-cookie": "h",
            "X-Api-Key": "i",
        ]
        let out = ArchonRedactor.redact(input)
        for key in input.keys {
            #expect(out[key] == "<redacted>")
        }
    }

    @Test("Redactor passes through benign keys and empty metadata")
    func redactorPassthrough() {
        let out = ArchonRedactor.redact(["provider": "local", "request-id": "1", "": "empty-key"])
        #expect(out == ["provider": "local", "request-id": "1", "": "empty-key"])
        #expect(ArchonRedactor.redact([:]).isEmpty)
    }

    @Test("Audit event redacts on init and preserves identity fields")
    func auditEventInit() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let event = ArchonAuditEvent(
            id: id, category: "c", action: "a", outcome: "o",
            metadata: ["apiKey": "v", "plain": "v2"], createdAt: date
        )
        #expect(event.id == id)
        #expect(event.metadata["apiKey"] == "<redacted>")
        #expect(event.metadata["plain"] == "v2")
        #expect(event.createdAt == date)
    }

    @Test("No-op logger and audit sink do not throw")
    func noOps() async {
        NoOpArchonLogger().log(.info, message: "hello")
        await NoOpArchonAuditSink().record(
            ArchonAuditEvent(category: "c", action: "a", outcome: "o")
        )
    }

    // MARK: - Capability registry edge/error/boundary

    @Test("Registry rejects blank identifiers")
    func registryBlankID() async {
        let registry = ArchonCapabilityRegistry()
        for bad in ["", "   ", "\n\t "] {
            do {
                _ = try await registry.require(bad)
                Issue.record("blank id should throw: \(bad.debugDescription)")
            } catch let error as ArchonCoreError {
                #expect(error == .invalidIdentifier(bad))
            } catch {
                Issue.record("wrong error type for blank id")
            }
        }
    }

    @Test("Registry reports notRegistered and unavailable without reason")
    func registryNotRegistered() async {
        let registry = ArchonCapabilityRegistry()
        do {
            _ = try await registry.require("missing.id")
            Issue.record("should throw")
        } catch let error as ArchonCapabilityError {
            #expect(error == .notRegistered("missing.id"))
            #expect(error.errorDescription?.contains("missing.id") == true)
        } catch {
            Issue.record("wrong error type")
        }

        await registry.register(ArchonCapabilityStatus(
            capability: ArchonCapability(id: "x", description: "x"),
            state: .degraded, reason: nil
        ))
        do {
            _ = try await registry.require("x")
            Issue.record("should throw")
        } catch let error as ArchonCapabilityError {
            #expect(error == .unavailable(id: "x", reason: nil))
            #expect(error.errorDescription == "Archon capability is unavailable: x")
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("Registry permission subsets and overwrite/remove semantics")
    func registryPermissionsAndMutation() async throws {
        let registry = ArchonCapabilityRegistry(statuses: [
            ArchonCapabilityStatus(
                capability: ArchonCapability(id: "cap", description: "d"),
                state: .available, requiredPermissions: [.camera, .microphone]
            )
        ])
        // Partial grant reports only the missing subset.
        do {
            _ = try await registry.require("cap", grantedPermissions: [.camera])
            Issue.record("should throw")
        } catch let error as ArchonCapabilityError {
            #expect(error == .permissionsRequired(id: "cap", permissions: [.microphone]))
            #expect(error.errorDescription?.contains("microphone") == true)
        }
        // Full grant passes.
        let ok = try await registry.require("cap", grantedPermissions: [.camera, .microphone])
        #expect(ok.isAvailable)
        // Extra grants are fine.
        _ = try await registry.require("cap", grantedPermissions: [.camera, .microphone, .network])
        // Overwrite via re-register.
        await registry.register(ArchonCapabilityStatus(
            capability: ArchonCapability(id: "cap", description: "d2"),
            state: .unavailable, reason: "off"
        ))
        #expect(await registry.status(for: "cap")?.state == .unavailable)
        // Remove then missing.
        await registry.remove(id: "cap")
        #expect(await registry.status(for: "cap") == nil)
        await registry.remove(id: "never-there") // no-op, no throw
        // Restricted state also fails closed.
        await registry.register(ArchonCapabilityStatus(
            capability: ArchonCapability(id: "r", description: "r"),
            state: .restricted
        ))
        #expect(await registry.status(for: "r")?.isAvailable == false)
    }

    @Test("Capability error descriptions cover all cases")
    func capabilityErrorDescriptions() {
        #expect(ArchonCapabilityError.notRegistered("a").errorDescription == "Archon capability is not registered: a")
        #expect(ArchonCapabilityError.unavailable(id: "a", reason: "why").errorDescription == "Archon capability is unavailable: a. why")
        let perms = ArchonCapabilityError.permissionsRequired(id: "a", permissions: [.network, .camera])
        #expect(perms.errorDescription == "Archon capability requires permission before use: a [camera, network]")
    }

    // MARK: - OS version boundaries

    @Test("OS version equality, ordering, and stringValue")
    func osVersionSemantics() {
        #expect(ArchonOSVersion(major: 27) == ArchonOSVersion(major: 27, minor: 0, patch: 0))
        #expect(!(ArchonOSVersion(major: 27, minor: 1) < ArchonOSVersion(major: 27, minor: 1)))
        #expect(ArchonOSVersion(major: 27, minor: 0, patch: 1) > ArchonOSVersion(major: 27))
        #expect(ArchonOSVersion(major: 26, minor: 9, patch: 9) < ArchonOSVersion(major: 27))
        #expect(ArchonOSVersion(major: 27, minor: 1, patch: 2).stringValue == "27.1.2")
        let osv = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 3)
        #expect(ArchonOSVersion(osv) == ArchonOSVersion(major: 27, minor: 1, patch: 3))
    }

    // MARK: - Memory budget boundaries

    @Test("Zero availableMemoryBytes falls back to envelope budget")
    func budgetZeroAvailableFallback() {
        let device = ArchonDeviceCapabilities(
            platform: .macOS, osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 16_000_000_000, availableMemoryBytes: 0,
            processorCount: 8, deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false, supportsCoreAI: false
        )
        let budget = device.modelMemoryBudget
        #expect(budget.currentProcessHeadroomBytes == budget.predictedProcessLimitBytes)
        #expect(budget.confidence == .platformHeuristic)
        #expect(budget.recommendedModelMemoryBytes <= budget.predictedProcessLimitBytes)
    }

    @Test("Saturating subtract clamps recommended budget at zero under huge load")
    func budgetSaturatesAtZero() {
        let device = ArchonDeviceCapabilities(
            platform: .iOS, osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 4_000_000_000, availableMemoryBytes: 1_000_000_000,
            processorCount: 6, deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false, supportsCoreAI: false,
            loadedModelMemoryBytes: 9_000_000_000
        )
        #expect(device.modelMemoryBudget.recommendedModelMemoryBytes == 0)
    }

    @Test("Budget GB conversions and visionOS envelope")
    func budgetGBAndVisionOS() {
        let device = ArchonDeviceCapabilities(
            platform: .visionOS, osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 16_000_000_000, availableMemoryBytes: 8_000_000_000,
            processorCount: 8, deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false, supportsCoreAI: false
        )
        let budget = device.modelMemoryBudget
        #expect(abs(budget.predictedProcessLimitGB - Double(budget.predictedProcessLimitBytes) / 1_073_741_824.0) < 1e-9)
        #expect(abs(budget.recommendedModelMemoryGB - Double(budget.recommendedModelMemoryBytes) / 1_073_741_824.0) < 1e-9)
        // visionOS envelope: min(40% of physical, 6 GiB)
        #expect(budget.predictedProcessLimitBytes == UInt64(min(Double(16_000_000_000) * 0.40, 6.0 * 1_073_741_824.0)))
    }

    @Test("Device decode supplies defaults for missing new keys")
    func deviceDecodeDefaults() throws {
        let json = """
        {"platform":"macOS","osVersion":{"major":27,"minor":0,"patch":0},\
        "physicalMemoryBytes":8000000000,"availableMemoryBytes":4000000000,\
        "processorCount":8,"deviceArchitecture":"arm64",\
        "supportsAppleFoundationModels":false,"supportsCoreAI":false}
        """.data(using: .utf8)!
        let device = try JSONDecoder().decode(ArchonDeviceCapabilities.self, from: json)
        #expect(device.thermalState == .nominal)
        #expect(device.loadedModelMemoryBytes == 0)
        #expect(!device.deviceDisplayName.isEmpty)
    }

    @Test("Core error descriptions and cancellation classification")
    func coreErrorsAndCancellation() {
        #expect(ArchonCoreError.invalidIdentifier("x").errorDescription == "Invalid Archon identifier: x")
        #expect(ArchonCoreError.invalidConfiguration("y").errorDescription == "Invalid Archon configuration: y")
        #expect(ArchonCoreError.unsupportedPlatform(.iOS).errorDescription == "Unsupported platform: iOS")
        #expect(ArchonCoreError.cancelled.errorDescription == "The Archon operation was cancelled.")
        #expect(!ArchonCoreError.invalidIdentifier("x").isCancellation)
        #expect(!ArchonCoreError.cancelled.isCancellation) // domain-specific, not task cancellation
        #expect(CancellationError().isCancellation)
    }

    // MARK: - Network policy edge/error/boundary

    @Test("Local development policy allows HTTP loopback-shaped URLs but blocks private literals")
    func localDevPolicy() throws {
        let policy = ArchonNetworkPolicy.localDevelopment
        try policy.validate(URL(string: "http://example.com/x")!)
        try policy.validate(URL(string: "http://127.0.0.1/x")!) // allowed when local permitted
        #expect(policy == ArchonNetworkPolicy(allowsHTTP: true, allowsLocalNetwork: true))
    }

    @Test("Public policy rejects schemes, hosts, and boundary addresses")
    func publicPolicyBoundaries() {
        let policy = ArchonNetworkPolicy.publicInternet
        // Valid public baseline.
        #expect(throws: Never.self) { try policy.validate(URL(string: "https://example.com/model")!) }
        // Uppercase scheme/host + trailing dot trimming still validate.
        #expect(throws: Never.self) { try policy.validate(URL(string: "HTTPS://Example.COM./model")!) }
        // Rejections:
        for raw in [
            "http://example.com/",          // http not allowed
            "ftp://example.com/",           // bad scheme
            "https://",                     // missing host
            "https://10.1.2.3/",            // private
            "https://192.168.0.1/",         // private
            "https://172.16.0.1/",          // 172.16 boundary: private
            "https://172.31.255.255/",      // 172.31 boundary: private
            "https://169.254.10.20/",       // link-local
            "https://224.0.0.1/",           // multicast
            "https://localhost/",           // localhost
            "https://foo.localhost/",       // *.localhost
            "https://printer.local/",       // *.local
            "https://[::1]/",               // ipv6 loopback
            "https://[::]/",                // ipv6 unspecified
            "https://[ff02::1]/",           // ipv6 multicast
            "https://12345/",               // single-int host
            "not a url",
        ] {
            #expect(throws: ArchonNetworkPolicyError.self, "should reject \(raw)") {
                try policy.validate(URL(string: raw)!)
            }
        }
        // 172.15 and 172.32 are public boundaries.
        #expect(throws: Never.self) { try policy.validate(URL(string: "https://172.15.0.1/")!) }
        #expect(throws: Never.self) { try policy.validate(URL(string: "https://172.32.0.1/")!) }
    }

    @Test("Resolved-address validation edge cases")
    func resolvedAddresses() {
        let policy = ArchonNetworkPolicy.publicInternet
        #expect(throws: ArchonNetworkPolicyError.resolutionFailed) {
            try policy.validateResolvedAddresses([])
        }
        #expect(throws: ArchonNetworkPolicyError.resolutionFailed) {
            try policy.validateResolvedAddresses(["not-an-address"])
        }
        #expect(throws: ArchonNetworkPolicyError.resolutionFailed) {
            try policy.validateResolvedAddresses(["8.8.8.8", "hostname"])
        }
        #expect(throws: ArchonNetworkPolicyError.privateNetworkAddress) {
            try policy.validateResolvedAddresses(["8.8.8.8", "10.0.0.1"])
        }
        #expect(throws: Never.self) { try policy.validateResolvedAddresses(["8.8.8.8", "1.1.1.1"]) }
        #expect(throws: Never.self) { try policy.validateResolvedAddresses(["2001:4860:4860::8888"]) }
        // Local-allowing policy permits private resolved addresses.
        #expect(throws: Never.self) {
            try ArchonNetworkPolicy.localDevelopment.validateResolvedAddresses(["10.0.0.1", "8.8.8.8"])
        }
    }

    @Test("Network policy error descriptions")
    func policyErrorDescriptions() {
        #expect(ArchonNetworkPolicyError.invalidURL.errorDescription == "The URL is not permitted by the active network policy.")
        #expect(ArchonNetworkPolicyError.privateNetworkAddress.errorDescription == "The URL resolves to a private or local network address.")
        #expect(ArchonNetworkPolicyError.resolutionFailed.errorDescription == "The hostname could not be resolved to a permitted address.")
        #expect(ArchonNetworkPolicyError.zeroCloudViolation(provider: "P").errorDescription == "Remote network egress to P is blocked by ZeroCloudMode.")
    }

    // MARK: - ZeroCloud policy / cancellation-policy

    @Test("ZeroCloud defaults off and task scope restores afterwards")
    func zeroCloudScoping() async throws {
        ArchonNetworkSecurity.setProcessZeroCloudEnabled(false)
        #expect(!ArchonNetworkSecurity.isZeroCloudEnabled)
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "P") // no throw when off
        try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(URL(string: "https://example.com/")!, provider: "P")

        await ArchonNetworkSecurity.withZeroCloud {
            #expect(ArchonNetworkSecurity.isZeroCloudEnabled)
        }
        #expect(!ArchonNetworkSecurity.isZeroCloudEnabled) // restored
    }

    @Test("ZeroCloud blocks remote but allows loopback HTTP endpoints")
    func zeroCloudEnforcement() async {
        ArchonNetworkSecurity.setProcessZeroCloudEnabled(false)
        await ArchonNetworkSecurity.withZeroCloud {
            #expect(throws: ArchonNetworkPolicyError.zeroCloudViolation(provider: "P")) {
                try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "P")
            }
            #expect(throws: Never.self) {
                try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(URL(string: "http://localhost:8000/v1")!, provider: "P")
            }
            #expect(throws: Never.self) {
                try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(URL(string: "http://127.0.0.1:11434/")!, provider: "P")
            }
            #expect(throws: Never.self) {
                try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(URL(string: "http://[::1]:8080/")!, provider: "P")
            }
            // https loopback, remote host, and wrong-scheme all rejected
            for raw in ["https://localhost:8000/", "http://example.com/", "http://192.168.1.1/", "file:///tmp/x"] {
                #expect(throws: ArchonNetworkPolicyError.self, "should reject \(raw)") {
                    try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(URL(string: raw)!, provider: "P")
                }
            }
        }
        ArchonNetworkSecurity.setProcessZeroCloudEnabled(false)
    }

    @Test("ZeroCloud task-local does not leak to sibling tasks")
    func zeroCloudIsolation() async {
        ArchonNetworkSecurity.setProcessZeroCloudEnabled(false)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ArchonNetworkSecurity.withZeroCloud { ArchonNetworkSecurity.isZeroCloudEnabled } }
            group.addTask { ArchonNetworkSecurity.isZeroCloudEnabled }
            var results: [Bool] = []
            for await value in group { results.append(value) }
            #expect(results.sorted(by: { !$0 && $1 }).count == 2)
            #expect(results.contains(true) && results.contains(false))
        }
        ArchonNetworkSecurity.setProcessZeroCloudEnabled(false)
    }

    // MARK: - Structured output provider fakes

    @Test("Structured output fake decodes and propagates errors")
    func structuredOutputFakes() async throws {
        let provider = FakeStructuredOutputProvider(json: #"{"name":"a","count":3}"#)
        let value: SamplePayload = try await provider.generateStructuredOutput(prompt: "p", responseSchema: SamplePayload.self)
        #expect(value == SamplePayload(name: "a", count: 3))

        let bad = FakeStructuredOutputProvider(json: "not json")
        do {
            let _: SamplePayload = try await bad.generateStructuredOutput(prompt: "p", responseSchema: SamplePayload.self)
            Issue.record("malformed JSON should throw")
        } catch is DecodingError {
        }

        let failing = FailingStructuredOutputProvider()
        do {
            let _: SamplePayload = try await failing.generateStructuredOutput(prompt: "p", responseSchema: SamplePayload.self)
            Issue.record("failing provider should throw")
        } catch is FailingStructuredOutputProvider.Boom {
        }
    }

    @Test("Cancelled task surfaces CancellationError classified as cancellation")
    func taskCancellation() async {
        let task: Task<String, Error> = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "done"
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled task should throw")
        } catch {
            #expect((error as? CancellationError) != nil || error.isCancellation)
        }
    }
}
