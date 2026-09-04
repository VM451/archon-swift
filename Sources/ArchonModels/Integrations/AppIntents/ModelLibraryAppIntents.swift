import AppIntents
import Foundation

/// A model-library entity exposed to Shortcuts, Spotlight, and Siri.
public struct InstalledModelEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Installed AI Model")
    public static let defaultQuery = InstalledModelEntityQuery()

    public let id: String
    public let displayName: String
    public let runtime: String
    public let format: String

    public init(
        id: String,
        displayName: String = "Installed AI Model",
        runtime: String = "",
        format: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.runtime = runtime
        self.format = format
    }

    fileprivate init(model: InstalledModel) {
        self.init(
            id: model.id,
            displayName: model.manifest.modelName,
            runtime: model.manifest.runtime.rawValue,
            format: model.manifest.format.rawValue
        )
    }

    public var displayRepresentation: DisplayRepresentation {
        let subtitle = [runtime, format].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(displayName)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)"
        )
    }
}

/// Resolves App Entity identifiers through the host-registered model library.
public struct InstalledModelEntityQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [InstalledModelEntity] {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        let models = try await library.installedModels()
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, InstalledModelEntity(model: $0)) })
        return identifiers.compactMap { byID[$0] }
    }

    public func suggestedEntities() async throws -> [InstalledModelEntity] {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        return try await library.installedModels().map(InstalledModelEntity.init(model:))
    }
}

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

/// Deletes a selected model entity through the same guarded library API used by the UI.
public struct DeleteInstalledModelEntityIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete Selected AI Model"
    public static let description = IntentDescription("Deletes a selected model from the Archon model library.")

    @Parameter(title: "Model")
    public var model: InstalledModelEntity

    public init() {
        self.model = InstalledModelEntity(id: "")
    }

    public init(model: InstalledModelEntity) {
        self.model = model
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let normalizedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
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
