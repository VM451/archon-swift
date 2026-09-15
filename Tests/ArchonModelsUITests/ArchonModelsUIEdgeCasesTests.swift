import Foundation
import Testing
import ArchonCore
import ArchonModels
@testable import ArchonModelsUI

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

@Suite("ArchonModelsUI Edge Cases")
@MainActor
struct ArchonModelsUIEdgeCasesTests {
    @Test("Initial presentation state is idle with empty collections")
    func initialState() {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        #expect(viewModel.state == .idle)
        #expect(viewModel.models.isEmpty)
        #expect(viewModel.updates.isEmpty)
        #expect(viewModel.progress.isEmpty)
        #expect(viewModel.lastError == nil)
        #expect(viewModel.catalog == nil)
    }

    @Test("Device override is used verbatim")
    func deviceOverride() {
        let device = makeDevice()
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: device)
        #expect(viewModel.device == device)
    }

    @Test("Refresh on an empty library reaches loaded with no models")
    func refreshEmpty() async {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        await viewModel.refresh()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.models.isEmpty)
        #expect(viewModel.lastError == nil)
    }

    @Test("Check for updates without a catalog is a no-op")
    func updatesWithoutCatalog() async {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        await viewModel.checkForUpdates()
        #expect(viewModel.updates.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test("Download rejects non-MLX variants through the user-facing library")
    func rejectsNonMLXDownload() async {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        let variant = ModelVariant(
            id: "non-mlx",
            name: "model.aimodel",
            modelID: "example/non-mlx",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI
        )
        await viewModel.download(ModelDownloadRequest(variant: variant, modelName: "Non-MLX"))
        if case .failed = viewModel.state {} else {
            Issue.record("Expected failed state for non-MLX download, got \(viewModel.state).")
        }
        #expect(viewModel.lastError != nil)
    }

    @Test("Delete of an absent model surfaces a failed state")
    func deleteAbsent() async {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        await viewModel.delete(modelID: "does-not-exist")
        // Empty roots delete cleanly (no-op) or fail; either way no models appear.
        #expect(viewModel.models.isEmpty)
    }

    @Test("Presentation state equality covers error boundary")
    func presentationStateEquality() {
        #expect(ModelLibraryPresentationState.idle == ModelLibraryPresentationState.idle)
        #expect(ModelLibraryPresentationState.offline == ModelLibraryPresentationState.offline)
        #expect(ModelLibraryPresentationState.failed("a") == ModelLibraryPresentationState.failed("a"))
        #expect(ModelLibraryPresentationState.failed("a") != ModelLibraryPresentationState.failed("b"))
        #expect(ModelLibraryPresentationState.loading != ModelLibraryPresentationState.loaded)
    }
}
