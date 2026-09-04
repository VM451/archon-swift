import Foundation
import Testing
@testable import ArchonModels

struct ModelLibraryAppIntentsTests {
    @Test("Installed model App Entity resolves through the registered library")
    func resolvesInstalledModelEntity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("archon-intent-test-\(UUID().uuidString)", isDirectory: true)
        let artifact = root.appendingPathComponent("sample.coreai", isDirectory: true)
        try fileManager.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("core-ai-fixture".utf8).write(to: artifact.appendingPathComponent("weights.bin"))

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let installed = try await library.importArtifact(at: artifact)
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

        let resolved = try await query.entities(for: [installed.id, "missing"])
        #expect(resolved.map(\.id) == [installed.id])

        _ = try await DeleteInstalledModelEntityIntent(model: try #require(suggestions.first)).perform()
        #expect(try await library.installedModels().isEmpty)
    }
}
