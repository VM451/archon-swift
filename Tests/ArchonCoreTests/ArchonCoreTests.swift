import Testing
import ArchonCore

struct ArchonCoreTests {
    @Test("Capability registry requires explicit host permissions")
    func capabilityRegistryFailsClosed() async throws {
        let registry = ArchonCapabilityRegistry(statuses: [
            ArchonCapabilityStatus(
                capability: ArchonCapability(id: "camera.capture", description: "Capture a camera frame."),
                state: .available,
                requiredPermissions: [.camera]
            ),
            ArchonCapabilityStatus(
                capability: ArchonCapability(id: "cloud.sync", description: "Synchronize records."),
                state: .unavailable,
                reason: "The host has disabled synchronization."
            )
        ])

        do {
            _ = try await registry.require("camera.capture")
            Issue.record("A capability requiring camera access must not pass without host authorization.")
        } catch let error as ArchonCapabilityError {
            #expect(error == .permissionsRequired(id: "camera.capture", permissions: [.camera]))
        }

        do {
            _ = try await registry.require("cloud.sync")
            Issue.record("An unavailable capability must fail closed.")
        } catch let error as ArchonCapabilityError {
            #expect(error == .unavailable(id: "cloud.sync", reason: "The host has disabled synchronization."))
        }
    }

    @Test("Capability registry returns stable discovery order")
    func capabilityRegistryDiscoveryOrder() async throws {
        let registry = ArchonCapabilityRegistry(statuses: [
            ArchonCapabilityStatus(
                capability: ArchonCapability(id: "z.last", description: "Last"),
                state: .available
            ),
            ArchonCapabilityStatus(
                capability: ArchonCapability(id: "a.first", description: "First"),
                state: .available
            )
        ])

        let statuses = await registry.allStatuses()
        let firstStatus = try await registry.require("a.first")

        #expect(statuses.map { $0.capability.id } == ["a.first", "z.last"])
        #expect(firstStatus.isAvailable)
    }

    @Test("OS versions compare semantically")
    func comparesOSVersions() {
        #expect(ArchonOSVersion(major: 27, minor: 1) > ArchonOSVersion(major: 27))
        #expect(ArchonOSVersion(major: 27, minor: 1) < ArchonOSVersion(major: 28))
    }

    @Test("Device model budget predicts a process envelope and preserves multiple reserves")
    func calculatesModelBudget() {
        let device = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 6_000_000_000,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: true,
            supportsCoreAI: true
        )

        let budget = device.modelMemoryBudget
        #expect(budget.predictedProcessLimitBytes == 3_221_225_472)
        #expect(budget.currentProcessHeadroomBytes == 3_221_225_472)
        #expect(budget.applicationGrowthReserveBytes == 800_000_000)
        #expect(budget.runtimeReserveBytes == 268_435_456)
        #expect(budget.dynamicSafetyReserveBytes == 322_122_547)
        #expect(budget.recommendedModelMemoryBytes == 1_830_667_469)
        #expect(device.recommendedModelMemoryBytes == budget.recommendedModelMemoryBytes)
    }

    @Test("Device model budget accounts for memory held by another model")
    func accountsForOtherLoadedModels() {
        let device = ArchonDeviceCapabilities(
            platform: .macOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 16_000_000_000,
            availableMemoryBytes: 12_000_000_000,
            processorCount: 10,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: true,
            supportsCoreAI: true,
            loadedModelMemoryBytes: 2_000_000_000
        )

        #expect(device.modelMemoryBudget.predictedProcessLimitBytes == 12_000_000_000)
        #expect(device.recommendedModelMemoryBytes == 6_663_129_088)
    }

    @Test("Capability status distinguishes unsupported and degraded states")
    func capabilityStatesRemainExplicit() {
        #expect(ArchonCapabilityState.allCases.contains(.unsupported))
        #expect(ArchonCapabilityState.allCases.contains(.degraded))
    }

    @Test("Audit events redact credential-shaped metadata")
    func auditEventsRedactSecrets() {
        let event = ArchonAuditEvent(
            category: "network",
            action: "request",
            outcome: "allowed",
            metadata: [
                "provider": "local",
                "authorization": "Bearer do-not-record",
                "request-id": "abc"
            ]
        )

        #expect(event.metadata["authorization"] == "<redacted>")
        #expect(event.metadata["provider"] == "local")
        #expect(event.metadata["request-id"] == "abc")
    }
}
