import Testing
import ArchonAgent
import ArchonCore
import ArchonModels

struct ModelRoutingTests {
    @Test("MLX lifecycle adapter rejects artifacts from another runtime")
    func rejectsNonMLXArtifact() async throws {
        let variant = ModelVariant(
            id: "coreai-model",
            name: "model.aimodel",
            modelID: "example/model",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI
        )
        let model = InstalledModel(
            id: "coreai-model",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let adapter = MLXModelRuntimeAdapter()

        do {
            try await adapter.load(model: model)
            Issue.record("MLX adapter unexpectedly accepted a Core AI artifact.")
        } catch let error as ArchonModelsError {
            #expect(error == .unsupportedArtifact("Only installed MLX artifacts can be loaded by MLXModelRuntimeAdapter."))
        }
    }

    @Test("Core AI lifecycle adapter rejects artifacts from another runtime")
    func rejectsNonCoreAIArtifact() async throws {
        let variant = ModelVariant(
            id: "mlx-model",
            name: "model.mlx",
            modelID: "example/model",
            source: .localImport,
            format: .mlx,
            runtime: .mlx
        )
        let model = InstalledModel(
            id: "mlx-model",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let adapter = CoreAIModelRuntimeAdapter()

        do {
            try await adapter.load(model: model)
            Issue.record("Core AI adapter unexpectedly accepted an MLX artifact.")
        } catch let error as ArchonModelsError {
            #expect(error == .unsupportedArtifact("Only installed Core AI artifacts can be loaded by CoreAIModelRuntimeAdapter."))
        }
    }

    @Test("Prefer-local policy selects Apple's system model when available")
    func prefersAppleSystemModel() {
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

        let selection = AgentModelRouter.select(policy: ModelPolicy(privacy: .preferLocal), device: device)

        #expect(selection == .appleFoundationModel)
    }

    @Test("Local-only policy uses Apple's system model before custom downloads")
    func localOnlyPrefersAppleSystemModel() {
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

        let selection = AgentModelRouter.select(policy: ModelPolicy(privacy: .localOnly), device: device)

        #expect(selection == .appleFoundationModel)
    }

    @Test("Local-only policy offers a compatible Core AI variant for download")
    func findsCompatibleCatalogVariant() {
        let device = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 6_000_000_000,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false,
            supportsCoreAI: true
        )
        let variant = ModelVariant(
            id: "qwen-coreai",
            name: "qwen.aimodel",
            modelID: "Qwen/Qwen3",
            source: .archonRegistry,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 100,
            estimatedMemoryBytes: 100
        )
        let model = ModelDescriptor(id: "Qwen/Qwen3", name: "Qwen3", publisher: "Qwen", source: .archonRegistry, variants: [variant])

        let selection = AgentModelRouter.select(policy: ModelPolicy(privacy: .localOnly), device: device, candidates: [model])

        if case .downloadRequired(let selected) = selection {
            #expect(selected.id == variant.id)
        } else {
            Issue.record("Expected a compatible catalog variant to be offered for download.")
        }
    }
}
