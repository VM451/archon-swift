import Foundation
import Testing
import ArchonCore
import ArchonModels
@testable import ArchonModelsUI

private func stackUIDevice() -> ArchonDeviceCapabilities {
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

@Suite("Models Stack UI Tests")
@MainActor
struct ModelsStackUITests {
    @Test("Attempt and progress mapping retains the latest snapshot")
    func attemptProgressMapping() {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-stack-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: stackUIDevice())
        viewModel.recordProgress(variantID: "v1", value: 0.5)
        viewModel.recordAttempt(
            variantID: "v1",
            attempt: ModelDownloadAttempt(
                attempt: 2,
                maxAttempts: 3,
                resumedFromBytes: 1024,
                deltaReusedBytes: 512
            )
        )
        #expect(viewModel.progress["v1"] == 0.5)
        let attempt = try! #require(viewModel.attempts["v1"])
        #expect(attempt.attempt == 2)
        #expect(attempt.maxAttempts == 3)
        #expect(attempt.resumedFromBytes == 1024)
        #expect(attempt.deltaReusedBytes == 512)
        #expect(viewModel.attemptDisplayError(variantID: "v1") == nil)
    }

    @Test("Attempt errors are redacted for display")
    func attemptErrorRedaction() {
        let library = ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-stack-ui-\(UUID().uuidString)"))
        let viewModel = ModelLibraryViewModel(library: library, device: stackUIDevice())
        viewModel.recordAttempt(
            variantID: "v1",
            attempt: ModelDownloadAttempt(
                attempt: 3,
                maxAttempts: 3,
                lastError: "fetch https://models.example.test/x failed for /tmp/staging token=abc"
            )
        )
        let display = try! #require(viewModel.attemptDisplayError(variantID: "v1"))
        #expect(!display.contains("https://models.example.test"))
        #expect(!display.contains("/tmp/staging"))
        #expect(!display.contains("token=abc"))
        #expect(viewModel.attemptDisplayError(variantID: "missing") == nil)
    }

    @Test("Raw failure text redaction strips addresses, paths, and credentials")
    func rawTextRedaction() {
        let redacted = ModelLibraryViewModel.redactedText("GET https://models.example.test/m rejected; see /var/log/x; api-key QWERTY")
        #expect(!redacted.contains("https://models.example.test"))
        #expect(!redacted.contains("/var/log/x"))
        #expect(!redacted.contains("QWERTY"))
        #expect(ModelLibraryViewModel.redactedText("   ") == "The model library operation failed.")
    }

    @Test("Status text appends bounded try counts")
    func statusTextAttempts() {
        #expect(ModelBrowserView.statusText("Downloading", attempt: nil) == "Downloading")
        let text = ModelBrowserView.statusText(
            "Downloading",
            attempt: ModelDownloadAttempt(attempt: 2, maxAttempts: 3)
        )
        #expect(text == "Downloading · try 2/3")
    }

    @Test("New model accessibility identifiers stay stable")
    func identifierStability() {
        #expect(ModelAccessibilityIDs.browserBenchmark(variantID: "v1") == "archon.models.browser.benchmark.v1")
        #expect(ModelAccessibilityIDs.detailBenchmark(variantID: "m1") == "archon.models.detail.benchmark.m1")
        #expect(ModelAccessibilityIDs.librarySize(modelID: "m1") == "archon.models.library.size.m1")
        #expect(ModelAccessibilityIDs.storageRow(modelID: "m1") == "archon.models.storage.row.m1")
        #expect(ModelAccessibilityIDs.storageTemp == "archon.models.storage.temp")
        #expect(ModelAccessibilityIDs.storageStaging == "archon.models.storage.staging")
    }
}
