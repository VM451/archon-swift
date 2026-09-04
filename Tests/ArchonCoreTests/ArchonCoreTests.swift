import Testing
import ArchonCore

struct ArchonCoreTests {
    @Test("OS versions compare semantically")
    func comparesOSVersions() {
        #expect(ArchonOSVersion(major: 27, minor: 1) > ArchonOSVersion(major: 27))
        #expect(ArchonOSVersion(major: 27, minor: 1) < ArchonOSVersion(major: 28))
    }

    @Test("Device model budget preserves application headroom")
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

        #expect(device.recommendedModelMemoryBytes == 4_000_000_000)
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

        #expect(device.recommendedModelMemoryBytes == 6_000_000_000)
    }
}
