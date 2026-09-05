import Foundation
import Testing
import ArchonAgent
import ArchonCore
import ArchonModels

@Suite("Generic Adaptive Model Catalog Tests")
struct AdaptiveModelCatalogTests {

    @Test("Adaptive routing selects a supplied non-Gemma MLX candidate")
    func selectsSuppliedNonGemmaCandidate() {
        let candidate = AdaptiveModelCandidate(
            id: "qwen3-0.6b-mlx",
            name: "Qwen3 0.6B 4-bit",
            family: "Qwen",
            source: .mlx(
                source: .huggingFace(id: "mlx-community/Qwen3-0.6B-4bit", revision: "main"),
                extraEOSTokens: []
            ),
            capabilities: .mlxLocal,
            // This is a predicted peak, not just the on-disk weight size.
            estimatedMemoryBytes: 700 * 1024 * 1024,
            modelSizeBytes: 600 * 1024 * 1024,
            parameterCount: 600_000_000,
            maxContextTokens: 8_192,
            minimumSystemRAMGB: 3.5,
            estimatedQualityScore: 0.7,
            estimatedTokensPerSecond: 30,
            estimatedPromptTokensPerSecond: 100,
            estimatedEnergyEfficiencyScore: 0.9,
            estimatedThermalScore: 0.9,
            supportedPlatforms: [.iOS],
            licenseIdentifier: "apache-2.0"
        )
        let catalog = AdaptiveModelCatalog(candidates: [candidate])

        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive, runtime: .preferMLX),
            hardwareProfile: .iPhone12Base,
            catalog: catalog
        )

        #expect(provider.backend == .mlx)
        #expect(provider.selectedModel?.id == candidate.id)
        #expect(provider.selectedModel?.family == "Qwen")
        #expect(provider.selectedGemmaVariant == nil)
    }

    @Test("Intelligence-first routing uses declared capacity when quality benchmarks are absent")
    func intelligenceFirstDoesNotAlwaysChooseSmallestModel() {
        let smaller = AdaptiveModelCandidate(
            id: "qwen-3b",
            name: "Qwen 3B",
            family: "Qwen",
            source: .mlx(source: .huggingFace(id: "mlx-community/Qwen-3B-4bit", revision: "main"), extraEOSTokens: []),
            estimatedMemoryBytes: 1 * 1024 * 1024 * 1024,
            modelSizeBytes: 800 * 1024 * 1024,
            parameterCount: 3_000_000_000,
            supportedPlatforms: [.macOS]
        )
        let stronger = AdaptiveModelCandidate(
            id: "qwen-7b",
            name: "Qwen 7B",
            family: "Qwen",
            source: .mlx(source: .huggingFace(id: "mlx-community/Qwen-7B-4bit", revision: "main"), extraEOSTokens: []),
            estimatedMemoryBytes: 2 * 1024 * 1024 * 1024,
            modelSizeBytes: 1_600 * 1024 * 1024,
            parameterCount: 7_000_000_000,
            supportedPlatforms: [.macOS]
        )
        let profile = DeviceHardwareProfile(
            platform: .macOS,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
            availableProcessMemoryBytes: 10 * 1024 * 1024 * 1024,
            processorCount: 10,
            isAppleFoundationModelSupported: false,
            isCoreAISupported: false
        )

        let selected = AdaptiveModelCatalog(candidates: [smaller, stronger]).resolve(
            for: profile,
            preference: .intelligenceFirst,
            runtime: .preferMLX
        )

        #expect(selected?.id == stronger.id)
    }

    @Test("Model descriptors become generic adaptive candidates without a family enum")
    func buildsCandidatesFromModelDescriptors() {
        let variant = ModelVariant(
            id: "qwen3-variant",
            name: "Qwen3 0.6B 4-bit",
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx,
            supportedPlatforms: [.iOS],
            parameterCount: 600_000_000,
            contextLength: 8_192,
            sizeBytes: 600 * 1024 * 1024,
            estimatedMemoryBytes: 400 * 1024 * 1024,
            estimatedQualityScore: 0.7,
            estimatedTokensPerSecond: 30
        )
        let descriptor = ModelDescriptor(
            id: "qwen3",
            name: "Qwen3 0.6B",
            publisher: "Qwen",
            family: "Qwen",
            source: .huggingFace,
            revision: "2026-09-01",
            license: ModelLicenseMetadata(identifier: "apache-2.0"),
            variants: [variant]
        )

        let catalog = AdaptiveModelCatalog(descriptors: [descriptor])
        let selected = catalog.resolve(
            for: .iPhone12Base,
            preference: .adaptive,
            runtime: .preferMLX
        )

        #expect(catalog.candidates.count == 1)
        #expect(selected?.id == "qwen3-variant")
        #expect(selected?.family == "Qwen")
        #expect(catalog.candidates.first?.parameterCount == 600_000_000)
        if case .mlx(let source, _) = catalog.candidates[0].source {
            #expect(source.identifier == "mlx-community/Qwen3-0.6B-4bit@2026-09-01")
        } else {
            Issue.record("Expected the MLX descriptor to produce an MLX adaptive source.")
        }
    }

    @Test("Catalog providers can be refreshed without changing the selector")
    func loadsFromCatalogProvider() async throws {
        let variant = ModelVariant(
            id: "mistral-variant",
            name: "Mistral 3B 4-bit",
            modelID: "mlx-community/Mistral-3B-4bit",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx,
            supportedPlatforms: [.macOS],
            contextLength: 8_192,
            sizeBytes: 2 * 1024 * 1024 * 1024,
            estimatedMemoryBytes: 3 * 1024 * 1024 * 1024
        )
        let coreAIVariant = ModelVariant(
            id: "mistral-coreai-variant",
            name: "Mistral Core AI export",
            modelID: "mistral-coreai",
            source: .appleCoreAI,
            format: .aimodel,
            runtime: .coreAI,
            supportedPlatforms: [.macOS],
            estimatedMemoryBytes: 3 * 1024 * 1024 * 1024
        )
        let provider = StaticModelCatalog(models: [
            ModelDescriptor(
                id: "mistral-3b",
                name: "Mistral 3B",
                publisher: "Mistral",
                family: "Mistral",
                source: .huggingFace,
                variants: [variant]
            ),
            ModelDescriptor(
                id: "mistral-coreai",
                name: "Mistral Core AI",
                publisher: "Mistral",
                family: "Mistral",
                source: .appleCoreAI,
                variants: [coreAIVariant]
            )
        ])

        let catalog = try await AdaptiveModelCatalog.load(
            from: provider,
            request: ModelSearchRequest(query: "", runtime: .mlx)
        )

        #expect(catalog.candidates.first?.family == "Mistral")
        #expect(catalog.candidates.first?.id == "mistral-variant")
        #expect(catalog.candidates.count == 1)
    }

    @Test("Core AI candidates are selected only when explicitly requested")
    func selectsCoreAICandidateWhenRequested() {
        let candidate = AdaptiveModelCandidate(
            id: "qwen3-coreai",
            name: "Qwen3 Core AI export",
            family: "Qwen",
            source: .coreAI(
                source: .modelIdentifier("qwen3.coreai"),
                computeUnit: .neuralEngineFirst
            ),
            capabilities: .coreAI,
            estimatedMemoryBytes: 2 * 1024 * 1024 * 1024,
            maxContextTokens: 8_192,
            minimumSystemRAMGB: 5.5,
            supportedPlatforms: [.macOS]
        )
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
            hardwareProfile: profile,
            catalog: AdaptiveModelCatalog(candidates: [candidate])
        )

        #expect(provider.backend == .coreAI)
        #expect(provider.selectedModel?.id == "qwen3-coreai")
        #expect(provider.selectedGemmaVariant == nil)
    }

    @Test("No compatible adaptive candidate fails closed")
    func failsClosedWhenCatalogCannotFit() {
        let candidate = AdaptiveModelCandidate(
            id: "oversized-model",
            name: "Oversized model",
            family: "Test",
            source: .mlx(
                source: .huggingFace(id: "example/oversized-model", revision: "main"),
                extraEOSTokens: []
            ),
            estimatedMemoryBytes: 8 * 1024 * 1024 * 1024,
            minimumSystemRAMGB: 64,
            supportedPlatforms: [.iOS]
        )

        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive, runtime: .preferMLX),
            hardwareProfile: .iPhone12Base,
            catalog: AdaptiveModelCatalog(candidates: [candidate])
        )

        #expect(provider.backend == .unavailable)
        #expect(provider.selectedModel == nil)
    }
}
