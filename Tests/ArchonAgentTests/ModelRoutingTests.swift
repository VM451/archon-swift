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

    @Test("Core AI lifecycle adapter delegates imported Core AI bundles to the runtime")
    func acceptsCoreAIBundleArtifact() async throws {
        let variant = ModelVariant(
            id: "coreai-bundle",
            name: "model.coreai",
            modelID: "example/model",
            source: .localImport,
            format: .coreAIBundle,
            runtime: .coreAI
        )
        let model = InstalledModel(
            id: "coreai-bundle",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let adapter = CoreAIModelRuntimeAdapter()

        do {
            try await adapter.load(model: model)
            Issue.record("An invalid temporary directory must not load as a Core AI model.")
        } catch let error as ArchonModelsError {
            #expect(error != .unsupportedArtifact("Only installed Core AI artifacts can be loaded by CoreAIModelRuntimeAdapter."))
        } catch is CoreAIProviderError {
            // The adapter reached the public Core AI runtime, which may be unavailable
            // or reject the fixture because this package test has no signed model asset.
        } catch {
            Issue.record("Unexpected Core AI lifecycle error: \(error)")
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

    @Test("Explicit Foundation Models preference remains local-only")
    func explicitFoundationModelsPreference() {
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

        let selection = AgentModelRouter.select(
            policy: ModelPolicy(
                privacy: .localOnly,
                preferredRuntime: .foundationModels
            ),
            device: device
        )

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

    @Test("Model routing does not select an experimental installed export")
    func rejectsExperimentalInstalledModel() {
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
            id: "experimental-coreai",
            name: "experimental.aimodel",
            modelID: "example/experimental",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 100,
            estimatedMemoryBytes: 100,
            isExperimental: true
        )
        let installed = InstalledModel(
            id: variant.id,
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Experimental")
        )

        let selection = AgentModelRouter.select(
            policy: ModelPolicy(privacy: .localOnly),
            device: device,
            installed: [installed]
        )

        #expect(selection == .unavailable("No compatible local model satisfies the requested policy."))
    }

    @Test("Model routing enforces streaming, tool, and structured-output requirements")
    func enforcesFullCapabilityContract() {
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
            id: "text-no-json",
            name: "text-no-json.aimodel",
            modelID: "example/text-no-json",
            source: .archonRegistry,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 100,
            estimatedMemoryBytes: 100,
            capabilities: ArchonModelCapabilities(
                tasks: [.textGeneration],
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsStructuredOutput: false
            )
        )

        let selection = AgentModelRouter.select(
            policy: ModelPolicy(
                privacy: .localOnly,
                requirements: ModelCapabilityRequirements(
                    task: .textGeneration,
                    requiresStreaming: true,
                    requiresToolCalling: true,
                    requiresStructuredOutput: true
                )
            ),
            device: device,
            candidates: [ModelDescriptor(
                id: variant.modelID,
                name: "Text No JSON",
                publisher: "Example",
                source: .archonRegistry,
                variants: [variant]
            )]
        )

        #expect(selection == .unavailable("No compatible local model satisfies the requested policy."))
    }

    private func foundationModelsDevice() -> ArchonDeviceCapabilities {
        ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 6_000_000_000,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: true,
            supportsCoreAI: true
        )
    }

    @Test("System-model fast path honors the full requirements contract")
    func fastPathNegotiatesFullRequirements() {
        let full = ModelCapabilityRequirements(
            task: .textGeneration,
            requiresStreaming: true,
            requiresToolCalling: true,
            requiresStructuredOutput: true
        )
        #expect(AgentModelRouter.select(
            policy: ModelPolicy(privacy: .localOnly, requirements: full),
            device: foundationModelsDevice()
        ) == .appleFoundationModel)
        #expect(AgentModelRouter.select(
            policy: ModelPolicy(privacy: .appleOnly, requirements: full),
            device: foundationModelsDevice()
        ) == .appleFoundationModel)
    }

    @Test("Vision requirements skip the system model for a compatible installed variant")
    func visionRequirementsSkipSystemModel() {
        let variant = ModelVariant(
            id: "vision-mlx",
            name: "vision.mlx",
            modelID: "example/vision",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            sizeBytes: 100,
            estimatedMemoryBytes: 100,
            capabilities: ArchonModelCapabilities(
                tasks: [.textGeneration, .vision],
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsStructuredOutput: true
            )
        )
        let installed = InstalledModel(
            id: variant.id,
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Vision")
        )
        let selection = AgentModelRouter.select(
            policy: ModelPolicy(
                privacy: .preferLocal,
                capability: .textGeneration,
                requirements: ModelCapabilityRequirements(
                    task: .vision,
                    requiresStreaming: true
                )
            ),
            device: foundationModelsDevice(),
            installed: [installed]
        )

        guard case .installed(let selected) = selection else {
            Issue.record("Expected the vision-capable installed variant, got \(selection).")
            return
        }
        #expect(selected.id == "vision-mlx")
    }

    @Test("Apple-only policy fails closed when requirements exceed the system model")
    func appleOnlyRejectsUnsatisfiedRequirements() {
        let selection = AgentModelRouter.select(
            policy: ModelPolicy(
                privacy: .appleOnly,
                capability: .textGeneration,
                requirements: ModelCapabilityRequirements(task: .vision)
            ),
            device: foundationModelsDevice()
        )
        #expect(selection == .unavailable("Apple Foundation Models do not satisfy the requested capability requirements."))
    }

    @Test("Prefer-local names the host remote fallback; local-only does not")
    func unavailableMessagesDistinguishRemoteFallback() {
        let legacyDevice = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 6_000_000_000,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: false,
            supportsCoreAI: false
        )
        let preferLocal = AgentModelRouter.select(
            policy: ModelPolicy(privacy: .preferLocal),
            device: legacyDevice
        )
        let localOnly = AgentModelRouter.select(
            policy: ModelPolicy(
                privacy: .localOnly,
                capability: .textGeneration,
                requirements: ModelCapabilityRequirements(task: .vision)
            ),
            device: foundationModelsDevice()
        )
        // Prefer-local with no compatible local option stays honest about the
        // host-owned remote path; local-only never suggests one.
        #expect(preferLocal == .unavailable("No compatible local model is installed or catalogued; a remote provider may be selected by the host application."))
        if case .unavailable(let reason) = localOnly {
            #expect(!reason.lowercased().contains("remote"))
        } else {
            Issue.record("Expected local-only vision routing to be unavailable, got \(localOnly).")
        }
    }
}
