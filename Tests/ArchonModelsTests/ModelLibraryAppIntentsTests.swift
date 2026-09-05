import Foundation
import Testing
@testable import ArchonModels

struct ModelLibraryAppIntentsTests {
    @Test("Model library actions are published as discoverable App Shortcuts")
    func publishesAppShortcuts() {
        #expect(ArchonModelAppShortcuts.appShortcuts.count == 2)
    }

    @Test("Installed model App Entity resolves through the registered library")
    func resolvesInstalledModelEntity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("archon-intent-test-\(UUID().uuidString)", isDirectory: true)
        let artifact = root.appendingPathComponent("sample.mlx", isDirectory: true)
        try fileManager.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test","quantization":{"bits":4,"group_size":32}}"#.utf8)
            .write(to: artifact.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: artifact.appendingPathComponent("tokenizer.json"))
        try Data("mlx-fixture".utf8).write(to: artifact.appendingPathComponent("weights.safetensors"))

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let installed = try await library.importArtifact(at: artifact)
        let legacyArtifact = root.appendingPathComponent("sample.coreai", isDirectory: true)
        try fileManager.createDirectory(at: legacyArtifact, withIntermediateDirectories: true)
        try Data("core-ai-fixture".utf8).write(to: legacyArtifact.appendingPathComponent("weights.bin"))
        let legacyInstalled = try await library.importArtifact(at: legacyArtifact)
        await ModelLibraryIntentRegistry.shared.register(library)
        defer {
            Task { await ModelLibraryIntentRegistry.shared.unregister() }
            try? fileManager.removeItem(at: root)
        }

        let query = InstalledModelEntityQuery()
        let suggestions = try await query.suggestedEntities()
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.id == installed.id)
        #expect(suggestions.first?.displayName == installed.manifest.modelName)
        #expect(try await library.installedModels().count == 2)
        #expect(try await library.installedMLXModels().map(\.id) == [installed.id])

        let resolved = try await query.entities(for: [installed.id, legacyInstalled.id, "missing"])
        #expect(resolved.map(\.id) == [installed.id])

        _ = try await DeleteInstalledModelEntityIntent(model: try #require(suggestions.first)).perform()
        #expect(try await library.installedMLXModels().isEmpty)
        #expect(try await library.installedModels().map(\.id) == [legacyInstalled.id])
    }
}
