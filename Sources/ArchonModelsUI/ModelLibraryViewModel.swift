import Foundation
import SwiftUI
import ArchonCore
import ArchonModels

public enum ModelLibraryPresentationState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case offline
    case failed(String)
}

/// Main-actor state boundary for model-management surfaces.
///
/// The view model owns presentation state only. The actor-backed
/// `ModelLibrary` remains the source of truth for installed artifacts and the
/// download manager remains the source of truth for transfer lifecycle.
@MainActor
public final class ModelLibraryViewModel: ObservableObject {
    @Published public private(set) var models: [InstalledModel] = []
    @Published public private(set) var updates: [String: ModelUpdateCandidate] = [:]
    @Published public private(set) var progress: [String: Double] = [:]
    @Published public private(set) var state: ModelLibraryPresentationState = .idle
    @Published public private(set) var lastError: String?
    /// Redacted error safe for SwiftUI surfaces. Never contains file paths,
    /// URLs, or credential-adjacent values; `lastError` keeps the detail.
    @Published public private(set) var userVisibleError: String?

    public let library: ModelLibrary
    public let catalog: (any ModelCatalogProvider)?
    public let downloadManager: ModelDownloadManager
    private let deviceOverride: ArchonDeviceCapabilities?

    /// Uses a supplied snapshot for deterministic previews/tests, or refreshes
    /// the public process-headroom estimate for each production operation.
    public var device: ArchonDeviceCapabilities {
        deviceOverride ?? .current
    }

    public init(
        library: ModelLibrary,
        catalog: (any ModelCatalogProvider)? = nil,
        downloadManager: ModelDownloadManager = ModelDownloadManager(),
        device: ArchonDeviceCapabilities? = nil
    ) {
        self.library = library
        // Keep every user-facing catalog operation on the directly-runnable
        // MLX contract, while allowing community publishers that provide the
        // actual converted MLX artifacts.
        self.catalog = catalog.map {
            if let mlxCatalog = $0 as? MLXModelCatalog { return mlxCatalog }
            return MLXModelCatalog(provider: $0)
        }
        self.downloadManager = downloadManager
        self.deviceOverride = device
    }

    public func refresh() async {
        state = .loading
        do {
            models = try await library.installedMLXModels()
            lastError = nil
            userVisibleError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            userVisibleError = Self.redactedMessage(for: error)
            state = .failed(error.localizedDescription)
        }
    }

    public func checkForUpdates() async {
        guard let catalog else { return }
        do {
            let candidates = try await library.checkForUpdates(using: catalog)
            updates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.installedModelID, $0) })
            lastError = nil
            userVisibleError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            userVisibleError = Self.redactedMessage(for: error)
            state = Self.isNetworkError(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    /// Records deterministic download progress clamped to 0...1. Out-of-range
    /// values from transfer callbacks fail closed to the nearest bound.
    public func recordProgress(variantID: String, value: Double) {
        progress[variantID] = min(max(value, 0), 1)
    }

    /// Redacted, user-safe error message. Strips file paths, URLs, and
    /// credential-adjacent values; fails closed to a generic message.
    public static func redactedMessage(for error: Error) -> String {
        if isNetworkError(error) {
            return "The model catalog is unreachable. Check the connection and try again."
        }
        let raw = error.localizedDescription
        var redacted = raw
        redacted = redacted.replacingOccurrences(of: #"(?i)[a-z][a-z0-9+.-]*://\S+"#, with: "<address>", options: .regularExpression)
        redacted = redacted.replacingOccurrences(of: #"/[^\s\"']+"#, with: "<path>", options: .regularExpression)
        redacted = redacted.replacingOccurrences(of: #"(?i)(token|secret|password|credential|authorization|api[-_ ]?key|cookie)[^\n]{0,40}"#, with: "$1 <redacted>", options: .regularExpression)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The model library operation failed." }
        return String(trimmed.prefix(300))
    }

    public func download(_ request: ModelDownloadRequest) async {
        guard request.variant.runtime == .mlx, request.variant.format == .mlx else {
            let message = "Only MLX model variants can be downloaded through the user-facing model library."
            lastError = message
            userVisibleError = message
            state = .failed(message)
            return
        }
        do {
            let events = try await downloadManager.download(request, into: library, on: device)
            for try await event in events {
                switch event.state {
                case .downloading(let value, _, _):
                    recordProgress(variantID: event.variantID, value: value)
                case .ready:
                    progress.removeValue(forKey: event.variantID)
                    await refresh()
                case .failed(let message):
                    lastError = message
                    userVisibleError = message
                    state = .failed(message)
                case .cancelled:
                    progress.removeValue(forKey: event.variantID)
                default:
                    break
                }
            }
        } catch is CancellationError {
            progress.removeValue(forKey: request.variant.id)
        } catch {
            lastError = error.localizedDescription
            userVisibleError = Self.redactedMessage(for: error)
            state = Self.isNetworkError(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    public func delete(modelID: String) async {
        do {
            try await library.delete(modelID: modelID)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            userVisibleError = Self.redactedMessage(for: error)
            state = .failed(error.localizedDescription)
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("network")
    }
}
