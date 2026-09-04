import Testing
@testable import ArchonModels
import ArchonCore

private actor MockRuntimeAdapter: ModelRuntimeAdapter {
    private(set) var loadedModelID: String?

    func load(model: InstalledModel) async throws { loadedModelID = model.id }
    func unload(model: InstalledModel) async { loadedModelID = nil }
}

private actor DelayedRuntimeAdapter: ModelRuntimeAdapter {
    func load(model: InstalledModel) async throws {
        try await Task.sleep(for: .seconds(5))
    }

    func unload(model: InstalledModel) async {}
}

struct ModelLoadManagerTests {
    @Test("Model load manager delegates lifecycle only after compatibility passes")
    func loadsAndUnloadsCompatibleModel() async throws {
        let variant = ModelVariant(
            id: "model",
            name: "model.aimodel",
            modelID: "example/model",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1,
            estimatedMemoryBytes: 1
        )
        let model = InstalledModel(
            id: "model",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let adapter = MockRuntimeAdapter()
        let manager = ModelLoadManager(adapter: adapter)
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

        try await manager.load(model, on: device)
        #expect(await manager.state(for: "model") == .ready)
        #expect(await adapter.loadedModelID == "model")

        await manager.unload(model)
        #expect(await manager.state(for: "model") == .unloaded)
    }

    @Test("Model load manager switches resident models explicitly")
    func switchesResidentModels() async throws {
        func makeModel(_ id: String) -> InstalledModel {
            let variant = ModelVariant(
                id: id,
                name: "\(id).aimodel",
                modelID: "example/\(id)",
                source: .localImport,
                format: .aimodel,
                runtime: .coreAI,
                sizeBytes: 1,
                estimatedMemoryBytes: 1
            )
            return InstalledModel(
                id: id,
                directoryURL: .temporaryDirectory,
                manifest: ArchonModelManifest(variant: variant, modelName: id)
            )
        }

        let first = makeModel("first")
        let second = makeModel("second")
        let manager = ModelLoadManager(adapter: MockRuntimeAdapter())
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

        try await manager.load(first, on: device)
        try await manager.switchTo(second, on: device)

        #expect(await manager.state(for: first.id) == .unloaded)
        #expect(await manager.state(for: second.id) == .ready)
        #expect(await manager.loadedModelIDs() == [second.id])
    }

    @Test("Model loading can be cancelled while warming")
    func cancelsWarmingModel() async throws {
        let variant = ModelVariant(
            id: "model-cancel",
            name: "model.aimodel",
            modelID: "example/model-cancel",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1,
            estimatedMemoryBytes: 1
        )
        let model = InstalledModel(
            id: "model-cancel",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let manager = ModelLoadManager(adapter: DelayedRuntimeAdapter())
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

        let loading = Task { try await manager.load(model, on: device) }
        try await Task.sleep(for: .milliseconds(50))
        await manager.cancelLoad(modelID: model.id)

        do {
            try await loading.value
            Issue.record("Expected model loading to be cancelled.")
        } catch let error as ArchonModelsError {
            #expect(error == .cancelled)
        }
        #expect(await manager.state(for: model.id) == .cancelled)
    }

    @Test("Cancelling the caller propagates to a warming model load")
    func callerCancellationCancelsWarmingModel() async throws {
        let variant = ModelVariant(
            id: "model-caller-cancel",
            name: "model.aimodel",
            modelID: "example/model-caller-cancel",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1,
            estimatedMemoryBytes: 1
        )
        let model = InstalledModel(
            id: "model-caller-cancel",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let manager = ModelLoadManager(adapter: DelayedRuntimeAdapter())
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

        let loading = Task { try await manager.load(model, on: device) }
        try await Task.sleep(for: .milliseconds(50))
        loading.cancel()

        do {
            try await loading.value
            Issue.record("Expected caller cancellation to stop model loading.")
        } catch let error as ArchonModelsError {
            #expect(error == .cancelled)
        }
        #expect(await manager.state(for: model.id) == .cancelled)
    }

    @Test("Unloading during a load cannot be overwritten by the suspended load")
    func unloadDuringLoadDoesNotResurrectModel() async throws {
        let variant = ModelVariant(
            id: "model-unload-during-load",
            name: "model.aimodel",
            modelID: "example/model-unload-during-load",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1,
            estimatedMemoryBytes: 1
        )
        let model = InstalledModel(
            id: "model-unload-during-load",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let manager = ModelLoadManager(adapter: DelayedRuntimeAdapter())
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

        let loading = Task { try await manager.load(model, on: device) }
        try await Task.sleep(for: .milliseconds(50))
        await manager.unload(model)

        do {
            try await loading.value
            Issue.record("Expected unloading to cancel the in-flight model load.")
        } catch let error as ArchonModelsError {
            #expect(error == .cancelled)
        }
        #expect(await manager.state(for: model.id) == .unloaded)
        #expect(await manager.loadedModel(id: model.id) == nil)
    }

    @Test("Model manager unloads resident models on critical pressure")
    func unloadsOnCriticalPressure() async throws {
        let variant = ModelVariant(
            id: "model-pressure",
            name: "model.aimodel",
            modelID: "example/model-pressure",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            estimatedMemoryBytes: 1
        )
        let model = InstalledModel(
            id: "model-pressure",
            directoryURL: .temporaryDirectory,
            manifest: ArchonModelManifest(variant: variant, modelName: "Example")
        )
        let manager = ModelLoadManager(adapter: MockRuntimeAdapter())
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

        try await manager.load(model, on: device)
        await manager.handleMemoryPressure(.critical)

        #expect(await manager.state(for: model.id) == .unloaded)
        #expect(await manager.loadedModelIDs().isEmpty)
    }
}
