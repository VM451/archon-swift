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

    @Test("iPhone 17 Pro test profile keeps the conservative mobile model envelope")
    func keepsIPhone17ProConservativeUntilDeviceEvidenceExists() {
        let profile = DeviceHardwareProfile.iPhone17Pro

        #expect(profile.memoryTier == .performance)
        #expect(profile.physicalMemoryGB >= 12.0)
        #expect(profile.safeModelMemoryBudgetMB == 1280)
        #expect(GemmaModelCatalog.safeResolve(for: profile, preference: .intelligenceFirst) == nil)
        #expect(GemmaModelCatalog.fits(GemmaModelCatalog.gemma4_9b_4bit, on: profile) == false)
    }

    @Test("Preserves the iPhone 16 process budget when dynamic headroom is transiently low")
    func keepsIPhone16LoadGateConsistentWithCatalogPreflight() {
        let profile = DeviceHardwareProfile.iPhone15Pro
        let transientDynamicRecommendation: UInt64 = 443_488_831

        let effectiveBudget = DeviceHardwareProfile.effectiveModelMemoryBudgetBytes(
            dynamicRecommendationBytes: transientDynamicRecommendation,
            profile: profile
        )

        #expect(effectiveBudget == profile.safeModelMemoryBudgetBytes)
        #expect(effectiveBudget >= 600_000_000)
    }

    @Test("Treats visionOS as a first-class Apple model-routing platform")
    func classifiesVisionOS() {
        let profile = DeviceHardwareProfile(
            platform: .visionOS,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 8 * 1024 * 1024 * 1024,
            availableProcessMemoryBytes: 6 * 1024 * 1024 * 1024,
            processorCount: 8,
            isAppleFoundationModelSupported: true,
            isCoreAISupported: true
        )

        #expect(profile.platform == .visionOS)
        #expect(profile.memoryTier == .performance)
        #expect(ApplePlatformKind.allCases.contains(.visionOS))
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

    @Test("iPhone 12 base rejects Gemma when the predicted peak exceeds the safe budget")
    func rejectsGemmaWhenIPhone12BudgetIsTooSmall() {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive),
            hardwareProfile: .iPhone12Base
        )

        #expect(provider.backend == .unavailable)
        #expect(provider.selectedGemmaVariant == nil)
        #expect(provider.id == "ondevice.unavailable")
    }

    @Test("Explicit Core AI preference selects Core AI for a supported device")
    func routesToCoreAIWhenExplicitlyPreferred() {
        let profile = DeviceHardwareProfile(
            platform: .macOS,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
            availableProcessMemoryBytes: 10 * 1024 * 1024 * 1024,
            processorCount: 10,
            isAppleFoundationModelSupported: false,
            isCoreAISupported: true
        )
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive, runtime: .preferCoreAI),
            hardwareProfile: profile
        )

        #expect(provider.backend == .coreAI)
        #expect(provider.selectedGemmaVariant != nil)
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("Automatic routing does not infer a Core AI export from hardware availability")
    func automaticRoutingKeepsMLXWithoutCoreAIArtifact() {
        let profile = DeviceHardwareProfile(
            platform: .macOS,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
            availableProcessMemoryBytes: 10 * 1024 * 1024 * 1024,
            processorCount: 10,
            isAppleFoundationModelSupported: false,
            isCoreAISupported: true
        )
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive, runtime: .auto),
            hardwareProfile: profile
        )

        #expect(provider.backend == .mlx)
        #expect(provider.selectedGemmaVariant != nil)
    }

    @Test("iPhone 14 Pro routes only to a Gemma variant that fits the predicted budget")
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
        #expect(intelligentProvider.selectedGemmaVariant?.huggingFaceID == "mlx-community/gemma-4-e2b-it-4bit")
    }

    @Test("Explicit strategy overrides still reject an oversized Gemma variant")
    func explicitStrategyOverrides() {
        let customGemma = OnDeviceProvider(
            strategy: .gemma(GemmaModelCatalog.gemma4_4b_4bit),
            hardwareProfile: .iPhone12Base
        )
        #expect(customGemma.backend == OnDeviceBackend.unavailable)
        #expect(customGemma.selectedGemmaVariant == nil)

        let localURL = URL(filePath: "/tmp/offline-gemma")
        let localDirProvider = OnDeviceProvider(
            strategy: .explicitMLXSource(.localDirectory(localURL)),
            hardwareProfile: .iPhone12Base
        )
        #expect(localDirProvider.backend == OnDeviceBackend.mlx)
        #expect(localDirProvider.id == "mlx./tmp/offline-gemma")
    }

    // MARK: - Cross-Platform (iPadOS & macOS) Routing Tests

    @Test("iPadOS: Entry iPad rejects an oversized local model; iPad Pro uses Apple Foundation Model")
    func iPadOSPlatformRouting() {
        let entryIPadProvider = OnDeviceProvider(
            strategy: .adaptive(),
            hardwareProfile: .iPadEntry
        )
        #expect(entryIPadProvider.hardwareProfile.platform == .iPadOS)
        #expect(entryIPadProvider.backend == OnDeviceBackend.unavailable)
        #expect(entryIPadProvider.selectedGemmaVariant == nil)

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

    @Test("Predicts model memory budget after host and pressure reserves")
    func processMemoryHeadroomBudget() {
        let iPhone12 = DeviceHardwareProfile.iPhone12Base
        #expect(iPhone12.appProcessMemoryLimitGB == 2.0)
        #expect(iPhone12.modelMemoryBudgetFraction == 0.50)
        #expect(iPhone12.safeModelMemoryBudgetMB == 1024)

        // The preference resolver remains a sizing hint; the safe resolver is
        // the runtime/download gate and correctly offers no model here.
        #expect(GemmaModelCatalog.safeResolve(for: iPhone12, preference: .adaptive) == nil)

        // iPhone 14 Pro with 3.0 GiB process envelope retains app/runtime/
        // pressure reserves before exposing the model budget.
        let iPhone14 = DeviceHardwareProfile.iPhone14Pro
        #expect(iPhone14.appProcessMemoryLimitGB == 3.0)
        #expect(iPhone14.safeModelMemoryBudgetMB == 1536)

        // Custom tight budget (e.g. 30% model budget) rejects even E2B when its
        // declared peak is larger than the remaining envelope.
        let tightBudgetProfile = DeviceHardwareProfile(
            platform: .iOS,
            physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 3 * 1024 * 1024 * 1024,
            modelMemoryBudgetFraction: 0.30, // 30% model budget = 900MB
            processorCount: 6,
            isAppleFoundationModelSupported: false
        )
        #expect(tightBudgetProfile.safeModelMemoryBudgetMB == 921)
        #expect(GemmaModelCatalog.safeResolve(for: tightBudgetProfile, preference: .intelligenceFirst) == nil)
    }
}
