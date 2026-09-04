import Foundation
import Testing
@testable import ArchonAgent

@Suite("Device Hardware Profiling & Gemma Sizing Tests")
struct OnDeviceModelSelectorTests {

    // MARK: - Hardware Profile Tier Tests

    @Test("Classifies 4GB iPhone as UltraLight tier")
    func classifiesIPhone12Base() {
        let profile = DeviceHardwareProfile.iPhone12Base

        #expect(profile.memoryTier == .ultraLight)
        #expect(profile.physicalMemoryGB < 5.0)
        #expect(!profile.isAppleFoundationModelSupported)
    }

    @Test("Classifies 6GB iPhone as Balanced tier")
    func classifiesIPhone14Pro() {
        let profile = DeviceHardwareProfile.iPhone14Pro

        #expect(profile.memoryTier == .balanced)
        #expect(profile.physicalMemoryGB >= 5.0 && profile.physicalMemoryGB < 7.9)
        #expect(!profile.isAppleFoundationModelSupported)
    }

    @Test("Classifies 8GB iPhone 15 Pro and 16GB Mac as Performance tier")
    func classifiesHighMemoryDevices() {
        let iPhone15Pro = DeviceHardwareProfile.iPhone15Pro
        #expect(iPhone15Pro.memoryTier == .performance)
        #expect(iPhone15Pro.physicalMemoryGB >= 8.0)
        #expect(iPhone15Pro.isAppleFoundationModelSupported)

        let mac = DeviceHardwareProfile.macAppleSilicon
        #expect(mac.memoryTier == .performance)
        #expect(mac.physicalMemoryGB >= 16.0)
        #expect(mac.isAppleFoundationModelSupported)
    }

    // MARK: - Gemma Model Catalog & Sizing Resolution Tests

    @Test("UltraLight tier selects Gemma 4 E2B in adaptive and speedFirst modes")
    func ultraLightTierSizing() {
        let adaptive = GemmaModelCatalog.resolve(for: .ultraLight, preference: .adaptive)
        #expect(adaptive.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(adaptive.estimatedMemoryMB <= 1500)

        let speedFirst = GemmaModelCatalog.resolve(for: .ultraLight, preference: .speedFirst)
        #expect(speedFirst.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")

        let intelligent = GemmaModelCatalog.resolve(for: .ultraLight, preference: .intelligenceFirst)
        #expect(intelligent.huggingFaceID == "mlx-community/gemma-4-e4b-it-4bit")
    }

    @Test("Balanced tier selects Gemma 4 E4B in adaptive and 4B in intelligenceFirst mode")
    func balancedTierSizing() {
        let adaptive = GemmaModelCatalog.resolve(for: .balanced, preference: .adaptive)
        #expect(adaptive.huggingFaceID == "mlx-community/gemma-4-e4b-it-4bit")

        let balanced = GemmaModelCatalog.resolve(for: .balanced, preference: .balanced)
        #expect(balanced.huggingFaceID == "mlx-community/gemma-4-e4b-it-4bit")

        let intelligent = GemmaModelCatalog.resolve(for: .balanced, preference: .intelligenceFirst)
        #expect(intelligent.huggingFaceID == "mlx-community/gemma-4-4b-it-4bit")
    }

    @Test("Performance tier selects high-capacity Gemma 4 9B in adaptive mode")
    func performanceTierSizing() {
        let adaptive = GemmaModelCatalog.resolve(for: .performance, preference: .adaptive)
        #expect(adaptive.huggingFaceID == "mlx-community/gemma-4-9b-it-4bit")
        #expect(adaptive.maxContextTokens >= 16384)

        let balanced = GemmaModelCatalog.resolve(for: .performance, preference: .balanced)
        #expect(balanced.huggingFaceID == "mlx-community/gemma-4-4b-it-4bit")
    }

    // MARK: - OnDeviceProvider Hardware-Aware Routing Tests

    @Test("iPhone 15 Pro routes to Apple Foundation Model as primary local engine")
    func routesToAppleFoundationModelOnSupportedHardware() {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive),
            hardwareProfile: .iPhone15Pro
        )

        #expect(provider.backend == .appleFoundationModel)
        #expect(provider.id == "apple.foundation.default")
        #expect(provider.selectedGemmaVariant == nil)
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("iPhone 12 base routes to MLX with Gemma 4 E2B 4-bit")
    func routesToMLXGemma4E2BOnIPhone12() {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive),
            hardwareProfile: .iPhone12Base
        )

        #expect(provider.backend == .mlx)
        #expect(provider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(provider.id == "mlx.mlx-community/gemma-4-e2b-it-4bit@main")
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("iPhone 14 Pro routes to MLX with Gemma 4 E2B in adaptive and E4B in intelligenceFirst mode")
    func routesToMLXGemma4OnIPhone14Pro() {
        let adaptiveProvider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive),
            hardwareProfile: .iPhone14Pro
        )

        #expect(adaptiveProvider.backend == .mlx)
        #expect(adaptiveProvider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(adaptiveProvider.id == "mlx.mlx-community/gemma-4-e2b-it-4bit@main")

        let intelligentProvider = OnDeviceProvider(
            strategy: .adaptive(preference: .intelligenceFirst),
            hardwareProfile: .iPhone14Pro
        )
        #expect(intelligentProvider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e4b-it-4bit")
    }

    @Test("Explicit strategy overrides allow forcing Gemma variants or local sources")
    func explicitStrategyOverrides() {
        let customGemma = OnDeviceProvider(
            strategy: .gemma(GemmaModelCatalog.gemma4_4b_4bit),
            hardwareProfile: .iPhone12Base
        )
        #expect(customGemma.backend == OnDeviceBackend.mlx)
        #expect(customGemma.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-4b-it-4bit")

        let localURL = URL(filePath: "/tmp/offline-gemma")
        let localDirProvider = OnDeviceProvider(
            strategy: .explicitMLXSource(.localDirectory(localURL)),
            hardwareProfile: .iPhone12Base
        )
        #expect(localDirProvider.backend == OnDeviceBackend.mlx)
        #expect(localDirProvider.id == "mlx./tmp/offline-gemma")
    }

    // MARK: - Cross-Platform (iPadOS & macOS) Routing Tests

    @Test("iPadOS: Entry iPad routes to MLX Gemma 4 E2B; iPad Pro M2 routes to Apple Foundation Model")
    func iPadOSPlatformRouting() {
        let entryIPadProvider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .iPadEntry
        )
        #expect(entryIPadProvider.hardwareProfile.platform == .iPadOS)
        #expect(entryIPadProvider.backend == OnDeviceBackend.mlx)
        #expect(entryIPadProvider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")

        let proIPadProvider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .iPadProM2
        )
        #expect(proIPadProvider.hardwareProfile.platform == .iPadOS)
        #expect(proIPadProvider.backend == OnDeviceBackend.appleFoundationModel)
    }

    @Test("macOS: Intel Mac routes to Performance Gemma 4 9B via MLX; Apple Silicon Mac routes to Apple Foundation Model")
    func macOSPlatformRouting() {
        let intelMacProvider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .macIntelLegacy
        )
        #expect(intelMacProvider.hardwareProfile.platform == .macOS)
        #expect(intelMacProvider.backend == OnDeviceBackend.mlx)
        #expect(intelMacProvider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-9b-it-4bit")

        let appleSiliconMacProvider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .macAppleSilicon
        )
        #expect(appleSiliconMacProvider.hardwareProfile.platform == .macOS)
        #expect(appleSiliconMacProvider.backend == OnDeviceBackend.appleFoundationModel)
    }

    @Test(
        "OnDeviceProvider generates with Apple Foundation Model when available",
        .enabled(if: ProcessInfo.processInfo.environment["ARCHON_ENABLE_LIVE_TESTS"] == "1")
    )
    func generationWithAppleFoundationModel() async throws {
        let provider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .iPhone15Pro
        )

        let response = try await provider.generate(prompt: [.user("Hello agent")])
        #expect(!response.text.isEmpty)
        #expect(response.finishReason == "stop")
    }

    // MARK: - Process Memory (Jetsam) & 50% Headroom Tests

    @Test("Enforces 50% model memory budget reserving remaining 50% for host app")
    func processMemoryHeadroomBudget() {
        let iPhone12 = DeviceHardwareProfile.iPhone12Base
        #expect(iPhone12.appProcessMemoryLimitGB == 2.0)
        #expect(iPhone12.modelMemoryBudgetFraction == 0.50)
        #expect(iPhone12.safeModelMemoryBudgetMB == 1024)

        // Resolving with constrained 1GB model budget forces lightweight E2B variant
        let resolved = GemmaModelCatalog.resolve(for: iPhone12, preference: .adaptive)
        #expect(resolved.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(resolved.estimatedMemoryMB <= 1500)

        // iPhone 14 Pro with 3.0 GB process limit has 1.5 GB model budget
        let iPhone14 = DeviceHardwareProfile.iPhone14Pro
        #expect(iPhone14.appProcessMemoryLimitGB == 3.0)
        #expect(iPhone14.safeModelMemoryBudgetMB == 1536)

        // Custom tight budget (e.g. 30% model budget) guarantees lightweight E2B
        let tightBudgetProfile = DeviceHardwareProfile(
            platform: .iOS,
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 3 * 1024 * 1024 * 1024,
            modelMemoryBudgetFraction: 0.30, // 30% model budget = 900MB
            processorCount: 6,
            isAppleFoundationModelSupported: false
        )
        #expect(tightBudgetProfile.safeModelMemoryBudgetMB == 921)
        let tightResolved = GemmaModelCatalog.resolve(for: tightBudgetProfile, preference: .intelligenceFirst)
        #expect(tightResolved.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
    }
}
