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

@Suite("ModelLibrary SwiftUI Hardening Tests")
@MainActor
struct ModelLibraryHardeningTests {
    @Test("Progress recording clamps to 0...1")
    func progressClamped() {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: makeDevice())
        viewModel.recordProgress(variantID: "v1", value: 2.5)
        #expect(viewModel.progress["v1"] == 1)
        viewModel.recordProgress(variantID: "v1", value: -0.5)
        #expect(viewModel.progress["v1"] == 0)
    }

    @Test("Redaction strips paths and addresses from surface errors")
    func redactionStripsSensitive() {
        struct Detailed: LocalizedError {
            var errorDescription: String? { "open /Users/me/models/auth token=abc https://models.example.test/x failed" }
        }
        let message = ModelLibraryViewModel.redactedMessage(for: Detailed())
        #expect(!message.contains("/Users/me"))
        #expect(!message.contains("https://models.example.test"))
        #expect(!message.contains("token=abc"))
    }

    @Test("Network errors map to an offline-safe message")
    func networkMapsOffline() {
        let message = ModelLibraryViewModel.redactedMessage(for: URLError(.notConnectedToInternet))
        #expect(message.localizedCaseInsensitiveContains("unreachable"))
        #expect(!message.contains("notConnectedToInternet") || message.localizedCaseInsensitiveContains("unreachable"))
    }
}
