import Foundation
import SwiftUI
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

    public let library: ModelLibrary
    public let catalog: (any ModelCatalogProvider)?
    public let downloadManager: ModelDownloadManager

    public init(
        library: ModelLibrary,
        catalog: (any ModelCatalogProvider)? = nil,
        downloadManager: ModelDownloadManager = ModelDownloadManager()
    ) {
        self.library = library
        self.catalog = catalog
        self.downloadManager = downloadManager
    }

    public func refresh() async {
        state = .loading
        do {
            models = try await library.installedModels()
            lastError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    public func checkForUpdates() async {
        guard let catalog else { return }
        do {
            let candidates = try await library.checkForUpdates(using: catalog)
            updates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.installedModelID, $0) })
            lastError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            state = Self.isNetworkError(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    public func download(_ request: ModelDownloadRequest) async {
        do {
            let events = try await downloadManager.download(request, into: library)
            for try await event in events {
                switch event.state {
                case .downloading(let value, _, _):
                    progress[event.variantID] = value
                case .ready:
                    progress.removeValue(forKey: event.variantID)
                    await refresh()
                case .failed(let message):
                    lastError = message
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
            state = Self.isNetworkError(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    public func delete(modelID: String) async {
        do {
            try await library.delete(modelID: modelID)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("network")
    }
}
