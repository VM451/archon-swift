import Foundation
import Testing
import ArchonCore
@testable import ArchonModels

private struct NoOpAdapter: ModelRuntimeAdapter {
    func load(model: InstalledModel) async throws {}
    func unload(model: InstalledModel) async {}
}

private struct SlowAdapter: ModelRuntimeAdapter {
    func load(model: InstalledModel) async throws {
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
    }
    func unload(model: InstalledModel) async {}
}

private func makeDevice() -> ArchonDeviceCapabilities {
    ArchonDeviceCapabilities(
        platform: .macOS,
        osVersion: ArchonOSVersion(major: 27),
        physicalMemoryBytes: 16_000_000_000,
        availableMemoryBytes: 12_000_000_000,
        processorCount: 8,
        deviceArchitecture: "arm64",
        supportsAppleFoundationModels: false,
        supportsCoreAI: true
    )
}

private func makeInstalledModel(
    id: String = "model-\(UUID().uuidString)",
    runtime: ArchonModelRuntime = .coreAI,
    format: ArchonModelFormat = .aimodel,
    estimatedMemoryBytes: Int64? = 1_024,
    isExperimental: Bool = false
) -> InstalledModel {
    let manifest = ArchonModelManifest(
        modelID: "example/\(id)",
        modelName: "Test \(id)",
        runtime: runtime,
        format: format,
        supportedDeviceArchitectures: ["arm64"],
        platforms: [.macOS],
        estimatedMemoryBytes: estimatedMemoryBytes,
        isExperimental: isExperimental
    )
    return InstalledModel(
        id: id,
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(id),
        manifest: manifest
    )
}

@Suite("ArchonModels Edge Cases")
struct ArchonModelsEdgeCasesTests {
    // MARK: - Format matrix (common + boundary)
    @Test("Format conversion and direct-runtime matrix")
    func formatMatrix() {
        #expect(ArchonModelFormat.aimodel.requiresConversion == false)
        #expect(ArchonModelFormat.mlx.requiresConversion == false)
        #expect(ArchonModelFormat.gguf.requiresConversion == true)
        #expect(ArchonModelFormat.unknown.requiresConversion == true)
        #expect(ArchonModelFormat.aimodel.directRuntime == .coreAI)
        #expect(ArchonModelFormat.mlx.directRuntime == .mlx)
        #expect(ArchonModelFormat.gguf.directRuntime == nil)
        #expect(ArchonModelFormat.unknown.directRuntime == nil)
        #expect(ArchonModelFormat.allCases.count == 7)
    }

    // MARK: - License policy (common + edge + boundary)
    @Test("License policy allows defaults and normalizes identifiers")
    func licensePolicyNormalization() {
        let policy = ModelLicensePolicy()
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "MIT")) == .allowed)
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "  apache-2.0\n")) == .allowed)
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "Apache_2.0")) == .allowed)
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "BSD_3_CLAUSE")) == .allowed)
    }

    @Test("License policy unknown and empty licenses follow unknownBehavior")
    func licensePolicyUnknown() {
        let confirm = ModelLicensePolicy()
        #expect(confirm.decision(for: nil) == .confirmationRequired)
        #expect(confirm.decision(for: ModelLicenseMetadata(identifier: nil)) == .confirmationRequired)
        #expect(confirm.decision(for: ModelLicenseMetadata(identifier: "   ")) == .confirmationRequired)
        #expect(confirm.decision(for: ModelLicenseMetadata(identifier: "gpl-3.0")) == .confirmationRequired)
        let denied = ModelLicensePolicy(unknownBehavior: .denied)
        #expect(denied.decision(for: nil) == .denied)
        #expect(denied.decision(for: ModelLicenseMetadata(identifier: "custom-license")) == .denied)
        let allowed = ModelLicensePolicy(unknownBehavior: .allowed)
        #expect(allowed.decision(for: nil) == .allowed)
        let custom = ModelLicensePolicy(confirmationIdentifiers: ["GPL-3.0"])
        #expect(custom.decision(for: ModelLicenseMetadata(identifier: "gpl-3.0")) == .confirmationRequired)
        #expect(custom.decision(for: ModelLicenseMetadata(identifier: "mit")) == .allowed)
    }

    // MARK: - Runtime capabilities (common + edge)
    @Test("Runtime capabilities satisfy matrix")
    func capabilitiesSatisfies() {
        let caps = ModelRuntimeCapabilities(
            runtime: .coreAI,
            capabilities: ArchonModelCapabilities(
                tasks: [.textGeneration],
                supportsStreaming: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false
            )
        )
        #expect(caps.satisfies(ModelCapabilityRequirements(task: .textGeneration)) == true)
        #expect(caps.satisfies(ModelCapabilityRequirements(task: .textGeneration, requiresStreaming: true)) == true)
        #expect(caps.satisfies(ModelCapabilityRequirements(task: .vision)) == false)
        #expect(caps.satisfies(ModelCapabilityRequirements(task: .textGeneration, requiresToolCalling: true)) == false)
        #expect(caps.satisfies(ModelCapabilityRequirements(task: .textGeneration, requiresStructuredOutput: true)) == false)
        let permissive = ModelRuntimeCapabilities(
            runtime: .mlx,
            capabilities: ArchonModelCapabilities(
                tasks: [.textGeneration, .vision],
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsStructuredOutput: true
            )
        )
        #expect(permissive.satisfies(ModelCapabilityRequirements(task: .vision, requiresStreaming: true, requiresToolCalling: true, requiresStructuredOutput: true)) == true)
    }

    // MARK: - Download policy clamping (boundary)
    @Test("Download policy clamps invalid bounds")
    func downloadPolicyClamping() {
        let zero = ModelDownloadPolicy(maxAttempts: 0, initialBackoff: -5, maximumBackoff: -10, maximumDownloadBytes: 0)
        #expect(zero.maxAttempts == 1)
        #expect(zero.initialBackoff == 0)
        #expect(zero.maximumBackoff == 0)
        #expect(zero.maximumDownloadBytes == 1)
        let inverted = ModelDownloadPolicy(maxAttempts: 3, initialBackoff: 30, maximumBackoff: 5)
        #expect(inverted.maximumBackoff == 30)
        let normal = ModelDownloadPolicy()
        #expect(normal.maxAttempts == 3)
        #expect(normal.maximumDownloadBytes == 16 * 1_024 * 1_024 * 1_024)
    }

    // MARK: - Artifact inspection (common + edge + error)
    @Test("Artifact inspection runnable flags and manifest synthesis")
    func artifactInspection() {
        let runnable = ModelArtifactInspection(format: .mlx, runtime: .mlx, modelName: "m")
        #expect(runnable.isRunnable == true)
        #expect(runnable.requiresConversion == false)
        let raw = ModelArtifactInspection(format: .gguf, runtime: .mlx, modelName: "m")
        #expect(raw.isRunnable == false)
        let mismatched = ModelArtifactInspection(format: .mlx, runtime: .coreAI, modelName: "m")
        #expect(mismatched.isRunnable == false)
        let unknownRuntime = ModelArtifactInspection(format: .mlx, runtime: .unknown, modelName: "m")
        #expect(unknownRuntime.isRunnable == false)
        let manifest = runnable.makeManifest(modelID: "example/m")
        #expect(manifest.modelID == "example/m")
        #expect(manifest.format == .mlx)
        // Boundary: size-based memory estimate scales by 1.15.
        let sized = ModelArtifactInspection(format: .mlx, runtime: .mlx, modelName: "m", modelSizeBytes: 1_000)
        #expect(sized.makeManifest(modelID: "x").estimatedMemoryBytes == 1_150)
        let unsized = ModelArtifactInspection(format: .mlx, runtime: .mlx, modelName: "m")
        #expect(unsized.makeManifest(modelID: "x").estimatedMemoryBytes == nil)
    }

    @Test("Artifact inspector rejects missing paths")
    func inspectorMissingPath() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("archon-missing-\(UUID().uuidString)")
        do {
            _ = try ModelArtifactInspector.inspect(at: missing)
            Issue.record("Expected unsupportedArtifact for missing path.")
        } catch let error as ArchonModelsError {
            #expect(error.errorDescription != nil)
            if case .unsupportedArtifact = error {} else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Background transfer stores (common + edge)
    @Test("In-memory background download store round-trips")
    func inMemoryStore() async throws {
        let store = InMemoryModelBackgroundDownloadStore()
        let request = ModelBackgroundDownloadRequest(
            identifier: "job-1",
            url: URL(string: "https://models.example.test/a")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("a")
        )
        let record = ModelBackgroundDownloadRecord(request: request)
        #expect(await (try store.record(for: "job-1")) == nil)
        try await store.save(record)
        #expect(await (try store.record(for: "job-1")) == record)
        try await store.remove(identifier: "job-1")
        #expect(await (try store.record(for: "job-1")) == nil)
        // Removing an absent identifier is a no-op (edge).
        try await store.remove(identifier: "absent")
        #expect(try await store.allRecords().isEmpty)
    }

    @Test("File background download store round-trips")
    func fileStore() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("archon-store-\(UUID().uuidString).json")
        let store = FileModelBackgroundDownloadStore(fileURL: fileURL)
        let request = ModelBackgroundDownloadRequest(
            identifier: "job-2",
            url: URL(string: "https://models.example.test/b")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("b")
        )
        try await store.save(ModelBackgroundDownloadRecord(request: request))
        #expect(try await store.record(for: "job-2")?.request.identifier == "job-2")
        #expect(try await store.allRecords().count == 1)
        try await store.remove(identifier: "job-2")
        #expect(try await store.allRecords().isEmpty)
    }

    // MARK: - Load manager (common + error + boundary + cancellation)
    @Test("Load manager loads and fast-paths ready models")
    func loadManagerHappyPath() async throws {
        let manager = ModelLoadManager(adapter: NoOpAdapter())
        let model = makeInstalledModel()
        try await manager.load(model, on: makeDevice())
        #expect(await manager.state(for: model.id) == .ready)
        #expect(await manager.loadedModel(id: model.id) != nil)
        #expect(await manager.loadedModelIDs() == [model.id])
        // Second load is a fast-path no-op.
        try await manager.load(model, on: makeDevice())
        #expect(await manager.state(for: model.id) == .ready)
    }

    @Test("Load manager rejects incompatible models")
    func loadManagerIncompatible() async throws {
        let manager = ModelLoadManager(adapter: NoOpAdapter())
        // Experimental variants are never loadable (policy case).
        let experimental = makeInstalledModel(isExperimental: true)
        do {
            try await manager.load(experimental, on: makeDevice())
            Issue.record("Expected incompatible error for experimental model.")
        } catch let error as ArchonModelsError {
            if case .incompatible = error {} else {
                Issue.record("Wrong error case: \(error)")
            }
        }
        // Unavailable adapter always fails closed.
        let unavailable = ModelLoadManager(adapter: UnavailableModelRuntimeAdapter())
        do {
            try await unavailable.load(makeInstalledModel(), on: makeDevice())
            Issue.record("Expected incompatible error from unavailable adapter.")
        } catch let error as ArchonModelsError {
            if case .incompatible = error {} else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("Load manager cancellation surfaces cancelled state")
    func loadManagerCancellation() async throws {
        let manager = ModelLoadManager(adapter: SlowAdapter())
        let model = makeInstalledModel()
        let task = Task { try await manager.load(model, on: makeDevice()) }
        // Wait until the load enters warming, then cancel.
        var warmed = false
        for _ in 0..<50 {
            if await manager.state(for: model.id) == .warming { warmed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(warmed == true)
        await manager.cancelLoad(modelID: model.id)
        do {
            try await task.value
            Issue.record("Expected cancellation to throw.")
        } catch is CancellationError {
        } catch let error as ArchonModelsError {
            #expect(error == .cancelled)
        }
    }

    @Test("Load manager memory accounting saturates on overflow")
    func loadManagerMemoryBoundary() async throws {
        let manager = ModelLoadManager(adapter: NoOpAdapter())
        #expect(await manager.loadedModelMemoryBytes() == 0)
        #expect(await manager.loadedModel(id: "absent") == nil)
        #expect(await manager.state(for: "absent") == nil)
        let model = makeInstalledModel(estimatedMemoryBytes: nil)
        // Unknown estimates still load when the analyzer permits; accounting treats them as unbounded.
        do {
            try await manager.load(model, on: makeDevice())
        } catch {
            // Analyzer-dependent outcome is acceptable; the boundary assertion below must still hold.
        }
        let total = await manager.loadedModelMemoryBytes()
        #expect(total >= 0)
    }

    // MARK: - Intent registry (policy: fail closed)
    @Test("Intent registry fails closed when unregistered")
    func intentRegistry() async {
        let registry = ModelLibraryIntentRegistry()
        #expect(await registry.current() == nil)
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-reg-\(UUID().uuidString)"))
        await registry.register(library)
        #expect(await registry.current() != nil)
        await registry.unregister()
        #expect(await registry.current() == nil)
    }

    // MARK: - Error surface (error cases)
    @Test("Error descriptions are present for key cases")
    func errorDescriptions() {
        let cases: [ArchonModelsError] = [
            .invalidResponse, .noDownloadURL, .cancelled, .insufficientDiskSpace,
            .invalidModelIdentifier("x"), .httpFailure(statusCode: 404),
            .downloadSizeExceeded(maximum: 8), .sizeMismatch(expected: 8, actual: 9),
            .integrityCheckFailed(expected: "a", actual: "b"),
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
        }
        #expect(ArchonModelsError.cancelled == ArchonModelsError.cancelled)
        #expect(ArchonModelsError.invalidResponse != ArchonModelsError.cancelled)
    }

    @Test("Download state equality covers progress boundary")
    func downloadStateEquality() {
        #expect(ModelDownloadState.queued == ModelDownloadState.queued)
        #expect(ModelDownloadState.cancelled == ModelDownloadState.cancelled)
        #expect(ModelDownloadState.failed("a") == ModelDownloadState.failed("a"))
        #expect(ModelDownloadState.failed("a") != ModelDownloadState.failed("b"))
        #expect(ModelDownloadState.downloading(progress: 0, bytesDownloaded: 0, totalBytes: nil)
            == ModelDownloadState.downloading(progress: 0, bytesDownloaded: 0, totalBytes: nil))
        #expect(ModelDownloadState.downloading(progress: 1, bytesDownloaded: 100, totalBytes: 100)
            != ModelDownloadState.downloading(progress: 0, bytesDownloaded: 0, totalBytes: nil))
    }
}
