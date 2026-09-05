import AppIntents
import Foundation

/// An MLX model-library entity exposed to Shortcuts, Spotlight, and Siri.
public struct InstalledModelEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Installed MLX Model")
    public static let defaultQuery = InstalledModelEntityQuery()

    public let id: String
    public let displayName: String
    public let runtime: String
    public let format: String

    public init(
        id: String,
        displayName: String = "Installed MLX Model",
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

/// Resolves MLX App Entity identifiers through the host-registered model library.
public struct InstalledModelEntityQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [InstalledModelEntity] {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        let models = try await library.installedMLXModels()
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, InstalledModelEntity(model: $0)) })
        return identifiers.compactMap { byID[$0] }
    }

    public func suggestedEntities() async throws -> [InstalledModelEntity] {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        return try await library.installedMLXModels().map(InstalledModelEntity.init(model:))
    }
}

/// Lists MLX models currently installed in the host application's Archon library.
public struct ListInstalledModelsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Installed MLX Models"
    public static let description = IntentDescription("Lists runnable MLX models installed in the Archon model library.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        let models = try await library.installedMLXModels()
        return .result(value: models.map { $0.manifest.modelName })
    }
}

/// Deletes a selected MLX model entity through the same guarded library API used by the UI.
public struct DeleteInstalledModelEntityIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete Selected MLX Model"
    public static let description = IntentDescription("Deletes a selected MLX model from the Archon model library.")

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
        guard let installed = try await library.installedModel(id: normalizedID),
              installed.manifest.runtime == .mlx,
              installed.manifest.format == .mlx else {
            throw ModelLibraryIntentError.notAnMLXModel
        }
        try await library.delete(modelID: installed.id)
        return .result(value: normalizedID)
    }
}

/// Reports managed model storage usage to Siri and Shortcuts.
public struct ModelLibraryStorageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check MLX Model Storage"
    public static let description = IntentDescription("Reports storage used by MLX models in the Archon model library.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let library = await ModelLibraryIntentRegistry.shared.current() else {
            throw ModelLibraryIntentError.libraryNotRegistered
        }
        return .result(value: String(try await library.mlxDiskUsageBytes()))
    }
}

/// Publishes the model-library actions as discoverable App Shortcuts. The
/// package provides the intents; the host still owns model-library
/// registration and therefore remains the source of truth for execution.
public struct ArchonModelAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListInstalledModelsIntent(),
            phrases: ["List installed MLX models in \(.applicationName)"],
            shortTitle: "List MLX Models",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: ModelLibraryStorageIntent(),
            phrases: ["Check MLX model storage in \(.applicationName)"],
            shortTitle: "Check MLX Storage",
            systemImageName: "internaldrive"
        )
    }
}

/// Deletes one installed MLX model through the same guarded library API used by the UI.
public struct DeleteInstalledModelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete Installed MLX Model"
    public static let description = IntentDescription("Deletes one MLX model from the Archon model library.")

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
        guard let installed = try await library.installedModel(id: normalizedID),
              installed.manifest.runtime == .mlx,
              installed.manifest.format == .mlx else {
            throw ModelLibraryIntentError.notAnMLXModel
        }
        try await library.delete(modelID: installed.id)
        return .result(value: normalizedID)
    }
}

private enum ModelLibraryIntentError: Error, LocalizedError, Sendable {
    case invalidModelID
    case libraryNotRegistered
    case notAnMLXModel

    var errorDescription: String? {
        switch self {
        case .invalidModelID:
            return "A non-empty installed model identifier is required."
        case .libraryNotRegistered:
            return "The host application has not registered its Archon model library for App Intents."
        case .notAnMLXModel:
            return "Only MLX models are exposed through Archon model-library actions."
        }
    }
}
