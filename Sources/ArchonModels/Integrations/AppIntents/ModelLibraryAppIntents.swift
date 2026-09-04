import AppIntents
import Foundation

/// Lists the models currently installed in the host application's Archon library.
public struct ListInstalledModelsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Installed AI Models"
    public static let description = IntentDescription("Lists runnable AI models installed in the Archon model library.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        let models = try await library.installedModels()
        return .result(value: models.map { $0.manifest.modelName })
    }
}

/// Reports managed model storage usage to Siri and Shortcuts.
public struct ModelLibraryStorageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check AI Model Storage"
    public static let description = IntentDescription("Reports storage used by the Archon model library.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        return .result(value: String(try await library.diskUsageBytes()))
    }
}

/// Deletes one installed model through the same guarded library API used by the UI.
public struct DeleteInstalledModelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete Installed AI Model"
    public static let description = IntentDescription("Deletes one model from the Archon model library.")

    @Parameter(title: "Model ID", description: "The exact installed model identifier.")
    public var modelID: String

    public init() {
        self.modelID = ""
    }

    public init(modelID: String) {
        self.modelID = modelID
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let normalizedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ModelLibraryIntentError.invalidModelID
        }
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        try await library.delete(modelID: normalizedID)
        return .result(value: normalizedID)
    }
}

private enum ModelLibraryIntentError: Error, LocalizedError, Sendable {
    case invalidModelID
    case libraryNotRegistered

    var errorDescription: String? {
        switch self {
        case .invalidModelID:
            return "A non-empty installed model identifier is required."
        case .libraryNotRegistered:
            return "The host application has not registered its Archon model library for App Intents."
        }
    }
}
