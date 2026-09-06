import CryptoKit
import Foundation
import ArchonCore

/// Host-owned bridge used by the optional model-library App Intents.
///
/// A consuming application should register its configured `ModelLibrary`
/// during startup. Intents fail closed when the host has not registered a
/// library, and the actor keeps registration race-free under Swift 6.
public actor ModelLibraryIntentRegistry {
    public static let shared = ModelLibraryIntentRegistry()

    private var library: ModelLibrary?

    public init() {}

    public func register(_ library: ModelLibrary) {
        self.library = library
    }

    public func unregister() {
        library = nil
    }

    public func current() -> ModelLibrary? {
        library
    }
}

public struct ModelDownloadRequest: Sendable {
    public let variant: ModelVariant
    public let modelName: String
    public let license: ModelLicenseMetadata?
    public let logoURL: URL?
    public let sourceRepository: String?
    public let sourceRevision: String?
    /// Existing managed-library installation to replace at the atomic commit
    /// boundary. This is set for explicit model updates; ordinary downloads
    /// derive their installation identity from the model and variant IDs.
    public let replacementInstallationID: String?

    public init(
        variant: ModelVariant,
        modelName: String,
        license: ModelLicenseMetadata? = nil,
        logoURL: URL? = nil,
        sourceRepository: String? = nil,
        sourceRevision: String? = nil,
        replacementInstallationID: String? = nil
    ) {
        self.variant = variant
        self.modelName = modelName
        self.license = license
        self.logoURL = logoURL
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision
        self.replacementInstallationID = replacementInstallationID
    }
}

/// Bounded retry policy for transient model-download failures. Integrity and
/// manifest failures are deterministic and are never retried.
public struct ModelDownloadPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let initialBackoff: TimeInterval
    public let maximumBackoff: TimeInterval
    /// Absolute per-download cap. This protects callers even when the server
    /// omits Content-Length and the manifest has no expected size.
    public let maximumDownloadBytes: Int64

    public init(
        maxAttempts: Int = 3,
        initialBackoff: TimeInterval = 1,
        maximumBackoff: TimeInterval = 30,
        maximumDownloadBytes: Int64 = 16 * 1024 * 1024 * 1024
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoff = max(0, initialBackoff)
        self.maximumBackoff = max(self.initialBackoff, maximumBackoff)
        self.maximumDownloadBytes = max(1, maximumDownloadBytes)
    }
}

enum ModelDownloadURLPolicy {
    static let maximumResponseBytes = 16 * 1024 * 1024

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let originalURL = task.originalRequest?.url,
                  let url = request.url,
                  ModelDownloadURLPolicy.validatesRedirect(from: originalURL, to: url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    static func validate(_ url: URL) throws {
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "Model download")
        do {
            try ArchonNetworkPolicy.publicInternet.validate(url)
        } catch {
            throw ArchonModelsError.invalidResponse
        }
    }

    static func validatesRedirect(from originalURL: URL, to newURL: URL) -> Bool {
        guard (try? validate(newURL)) != nil else { return false }
        let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        let target = URLComponents(url: newURL, resolvingAgainstBaseURL: false)
        return original?.scheme?.lowercased() == target?.scheme?.lowercased()
            && original?.host?.lowercased() == target?.host?.lowercased()
            && original?.port == target?.port
    }
}

private struct PendingModelDownload: Sendable {
    let url: URL
    let relativePath: String?
    let expectedSize: Int64?
    let checksum: String?
}

private struct BackgroundDownloadJob: Sendable {
    let coordinator: ModelBackgroundTransferCoordinator
    var transferIdentifiers: [String]
}

/// A byte-stream provider used by the foreground model downloader. The
/// default implementation is backed by `URLSession`; hosts and tests may
/// inject a transport to exercise cancellation, range resume, or custom
/// authentication without replacing the library's integrity pipeline.
public typealias ModelByteStreamProvider = @Sendable (
    URLRequest
) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse)

public enum ModelDownloadState: Sendable, Equatable {
    case queued
    case resolving
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64?)
    case paused
    case verifying
    case installing
    case ready(InstalledModel)
    case updateAvailable(ModelUpdateCandidate)
    case failed(String)
    case cancelled
}

public struct ModelDownloadEvent: Sendable {
    public let variantID: String
    public let state: ModelDownloadState

    public init(variantID: String, state: ModelDownloadState) {
        self.variantID = variantID
        self.state = state
    }
}

public enum ManagedModelState: String, Codable, CaseIterable, Sendable {
    case installed
    case warming
    case ready
    case idle
    case unloaded
    case cancelled
    case failed
}

public enum ModelMemoryPressure: String, Codable, CaseIterable, Sendable {
    case normal
    case warning
    case critical
}

/// Runtime boundary for Core AI, MLX, or another explicitly supported local runtime.
/// ArchonModels owns lifecycle and compatibility; the adapter owns Apple runtime calls.
public protocol ModelRuntimeAdapter: Sendable {
    func load(model: InstalledModel) async throws
    func unload(model: InstalledModel) async
}

public struct UnavailableModelRuntimeAdapter: ModelRuntimeAdapter, Sendable {
    public init() {}

    public func load(model: InstalledModel) async throws {
        throw ArchonModelsError.incompatible(.unsupportedFormat)
    }

    public func unload(model: InstalledModel) async {}
}

public actor ModelLoadManager {
    private let adapter: any ModelRuntimeAdapter
    private var states: [String: ManagedModelState] = [:]
    private var loadingTasks: [String: Task<Void, Error>] = [:]
    private var loadingOperationIDs: [String: UUID] = [:]
    private var models: [String: InstalledModel] = [:]
    private var lastUsedAt: [String: Date] = [:]

    public init(adapter: any ModelRuntimeAdapter = UnavailableModelRuntimeAdapter()) {
        self.adapter = adapter
    }

    public func state(for modelID: String) -> ManagedModelState? {
        states[modelID]
    }

    public func loadedModelIDs() -> [String] {
        states.compactMap { modelID, state in
            state == .ready || state == .idle ? modelID : nil
        }.sorted()
    }

    /// Returns a resident model, if it is loaded or idle in the runtime.
    public func loadedModel(id: String) -> InstalledModel? {
        guard states[id] == .ready || states[id] == .idle else { return nil }
        return models[id]
    }

    /// Returns the sum of predicted peak memory estimates for resident models.
    /// Unknown estimates count as unbounded so another model cannot be loaded
    /// beside a resident artifact whose peak cannot be proven safe.
    public func loadedModelMemoryBytes() -> UInt64 {
        models.reduce(into: UInt64(0)) { total, entry in
            guard states[entry.key] == .ready || states[entry.key] == .idle else { return }
            let estimate = residentMemoryEstimate(for: entry.value)
            let (sum, overflow) = total.addingReportingOverflow(estimate)
            total = overflow ? UInt64.max : sum
        }
    }

    public func load(_ model: InstalledModel, on device: ArchonDeviceCapabilities = .current) async throws {
        if states[model.id] == .ready {
            lastUsedAt[model.id] = Date()
            return
        }
        if states[model.id] == .idle {
            states[model.id] = .ready
            lastUsedAt[model.id] = Date()
            return
        }
        if states[model.id] == .warming { throw ArchonModelsError.modelLoadInProgress(model.id) }
        let variant = makeVariant(for: model)
        let residentMemory = models.reduce(into: UInt64(0)) { total, entry in
            guard entry.key != model.id,
                  states[entry.key] == .ready || states[entry.key] == .idle else { return }
            let estimate = residentMemoryEstimate(for: entry.value)
            let (sum, overflow) = total.addingReportingOverflow(estimate)
            total = overflow ? UInt64.max : sum
        }
        let deviceForLoad = ArchonDeviceCapabilities(
            platform: device.platform,
            osVersion: device.osVersion,
            physicalMemoryBytes: device.physicalMemoryBytes,
            availableMemoryBytes: device.availableMemoryBytes,
            processorCount: device.processorCount,
            deviceArchitecture: device.deviceArchitecture,
            supportsAppleFoundationModels: device.supportsAppleFoundationModels,
            supportsCoreAI: device.supportsCoreAI,
            thermalState: device.thermalState,
            loadedModelMemoryBytes: saturatingAdd(device.loadedModelMemoryBytes, residentMemory)
        )
        let compatibility = ModelCompatibilityAnalyzer.analyze(variant: variant, device: deviceForLoad, isInstalled: true)
        guard compatibility.canLoad else { throw ArchonModelsError.incompatible(compatibility.status) }

        states[model.id] = .warming
        models[model.id] = model
        lastUsedAt[model.id] = Date()
        let adapter = self.adapter
        let operationID = UUID()
        loadingOperationIDs[model.id] = operationID
        let task = Task {
            try await adapter.load(model: model)
            try Task.checkCancellation()
        }
        loadingTasks[model.id] = task
        do {
            try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            guard loadingOperationIDs[model.id] == operationID else {
                throw ArchonModelsError.cancelled
            }
            loadingTasks[model.id] = nil
            loadingOperationIDs[model.id] = nil
            guard states[model.id] == .warming else { return }
            states[model.id] = .ready
            lastUsedAt[model.id] = Date()
        } catch is CancellationError {
            guard loadingOperationIDs[model.id] == operationID else {
                throw ArchonModelsError.cancelled
            }
            loadingTasks[model.id] = nil
            loadingOperationIDs[model.id] = nil
            guard states[model.id] == .warming else { return }
            states[model.id] = .cancelled
            throw ArchonModelsError.cancelled
        } catch {
            guard loadingOperationIDs[model.id] == operationID else { throw error }
            loadingTasks[model.id] = nil
            loadingOperationIDs[model.id] = nil
            guard states[model.id] == .warming else { throw error }
            states[model.id] = .failed
            throw error
        }
    }

    public func cancelLoad(modelID: String) {
        loadingTasks[modelID]?.cancel()
    }

    private func makeVariant(for model: InstalledModel) -> ModelVariant {
        ModelVariant(
            id: model.id,
            name: model.manifest.modelName,
            modelID: model.manifest.modelID,
            source: .localImport,
            format: model.manifest.format,
            runtime: model.manifest.runtime,
            architecture: model.manifest.architecture,
            supportedDeviceArchitectures: model.manifest.supportedDeviceArchitectures,
            supportedPlatforms: model.manifest.platforms,
            minimumOS: model.manifest.minimumOS,
            parameterCount: model.manifest.parameterCount,
            contextLength: model.manifest.contextLength,
            precision: model.manifest.precision,
            quantization: model.manifest.quantization,
            kvCacheBytesPerToken: model.manifest.kvCacheBytesPerToken,
            sizeBytes: model.manifest.modelSizeBytes,
            estimatedMemoryBytes: model.manifest.estimatedMemoryBytes,
            estimatedQualityScore: model.manifest.estimatedQualityScore,
            estimatedTokensPerSecond: model.manifest.estimatedTokensPerSecond,
            sha256: model.manifest.checksum,
            resources: model.manifest.modelResources,
            tokenizerResources: model.manifest.tokenizerResources,
            capabilities: model.manifest.capabilities,
            isExperimental: model.manifest.isExperimental
        )
    }

    private func residentMemoryEstimate(for model: InstalledModel) -> UInt64 {
        // A resident local artifact without enough metadata to predict its
        // peak is treated as unbounded for subsequent load decisions.
        ModelCompatibilityAnalyzer.estimatedPeakMemoryBytes(for: makeVariant(for: model)) ?? UInt64.max
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    public func prewarm(_ model: InstalledModel, on device: ArchonDeviceCapabilities = .current) async throws {
        try await load(model, on: device)
    }

    /// Makes one installed model the active resident model. Existing resident
    /// models are unloaded before the new model is loaded so the compatibility
    /// check accounts for the memory they would otherwise consume.
    public func switchTo(_ model: InstalledModel, on device: ArchonDeviceCapabilities = .current) async throws {
        let residentModels = models.values.filter { $0.id != model.id && (states[$0.id] == .ready || states[$0.id] == .idle) }
        for residentModel in residentModels {
            await unload(residentModel)
        }
        do {
            try await load(model, on: device)
        } catch {
            // A failed replacement must not strand the previously usable
            // resident set. Restore it best-effort before returning the
            // original load error to the caller.
            for residentModel in residentModels {
                do {
                    try await load(residentModel, on: device)
                } catch {
                    // Preserve the replacement error; the restored state is
                    // observable through `state(for:)` and diagnostics.
                }
            }
            throw error
        }
    }

    public func markIdle(modelID: String) {
        guard states[modelID] == .ready else { return }
        states[modelID] = .idle
        lastUsedAt[modelID] = Date()
    }

    /// Gives the host app a safe hook for `UIApplication`/`NSApplication`
    /// background transitions. Apps may keep warm models or unload all of them.
    public func handleApplicationDidEnterBackground(unloadAll: Bool = false) async {
        if unloadAll {
            await cancelWarmingLoads()
        }
        await unloadLoadedModels(where: { state in unloadAll || state == .idle })
    }

    /// Responds to host memory-pressure notifications without relying on a
    /// private notification or a platform-specific app lifecycle object.
    public func handleMemoryPressure(_ pressure: ModelMemoryPressure) async {
        switch pressure {
        case .normal:
            break
        case .warning:
            await unloadIdleModels(olderThan: 0)
        case .critical:
            await cancelWarmingLoads()
            await unloadLoadedModels(where: { $0 == .ready || $0 == .idle })
        }
    }

    /// Responds to thermal state changes. Serious and critical states unload
    /// all resident models; new loads are separately rejected by compatibility.
    public func handleThermalState(_ thermalState: ArchonThermalState) async {
        guard thermalState == .serious || thermalState == .critical else { return }
        await cancelWarmingLoads()
        await unloadLoadedModels(where: { $0 == .ready || $0 == .idle })
    }

    /// Unloads idle models that have not been used for the requested interval.
    public func unloadIdleModels(olderThan age: TimeInterval) async {
        let cutoff = Date().addingTimeInterval(-max(age, 0))
        await unloadLoadedModels(
            where: { state in state == .idle },
            whereDate: { date in date <= cutoff }
        )
    }

    public func unload(_ model: InstalledModel) async {
        if let loadingTask = loadingTasks[model.id] {
            loadingOperationIDs[model.id] = nil
            loadingTask.cancel()
            _ = try? await loadingTask.value
            loadingTasks[model.id] = nil
        }
        await adapter.unload(model: model)
        states[model.id] = .unloaded
        models[model.id] = nil
        lastUsedAt[model.id] = nil
    }

    private func unloadLoadedModels(
        where predicate: (ManagedModelState) -> Bool,
        whereDate datePredicate: ((Date) -> Bool)? = nil
    ) async {
        let ids = states.compactMap { modelID, state -> String? in
            guard predicate(state) else { return nil }
            if let datePredicate, let date = lastUsedAt[modelID], !datePredicate(date) { return nil }
            return modelID
        }
        for modelID in ids {
            guard let model = models[modelID] else { continue }
            await adapter.unload(model: model)
            states[modelID] = .unloaded
            models[modelID] = nil
            lastUsedAt[modelID] = nil
        }
    }

    private func cancelWarmingLoads() async {
        let tasks = Array(loadingTasks.values)
        for task in tasks {
            task.cancel()
            _ = try? await task.value
        }
    }
}

/// Actor-isolated model library. Every install is staged and committed only after validation.
public actor ModelLibrary {
    public let rootURL: URL
    /// Optional lifecycle coordinator. Supplying the host's load manager lets
    /// deletion and replacement unload resident artifacts before filesystem
    /// mutation.
    public let loadManager: ModelLoadManager

    public init(rootURL: URL? = nil, loadManager: ModelLoadManager = ModelLoadManager()) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.loadManager = loadManager
    }

    public static func makeDefault() -> ModelLibrary {
        ModelLibrary()
    }

    public func installedModels() throws -> [InstalledModel] {
        try ensureRoot()
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let manifestURL = directory.appendingPathComponent(ArchonModelManifest.filename)
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            let decodedManifest = try JSONDecoder().decode(ArchonModelManifest.self, from: data)
            let manifest = decodedManifest.schemaVersion < ArchonModelManifest.currentSchemaVersion
                ? decodedManifest.withCurrentSchemaVersion()
                : decodedManifest
            if manifest != decodedManifest {
                let migratedData = try JSONEncoder.archonEncoder.encode(manifest)
                try migratedData.write(to: manifestURL, options: .atomic)
            }
            let installedAt = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let installed = InstalledModel(id: directory.lastPathComponent, directoryURL: directory, manifest: manifest, installedAt: installedAt)
            let validation = ModelManifestValidator.validate(manifest, artifactAt: installed.artifactURL)
            guard validation.isValid else { throw ArchonModelsError.invalidManifest(validation.errors) }
            return installed
        }.sorted { $0.id < $1.id }
    }

    /// Returns the models eligible for the package's user-facing local model
    /// surfaces. Lower-level inspection APIs remain available for hosts that
    /// need to reason about other artifact families explicitly.
    public func installedMLXModels() throws -> [InstalledModel] {
        try installedModels().filter {
            $0.manifest.runtime == .mlx && $0.manifest.format == .mlx
        }
    }

    public func contains(modelID: String) throws -> Bool {
        try installedModels().contains { $0.manifest.modelID == modelID || $0.id == modelID }
    }

    public func installedModel(id: String) throws -> InstalledModel? {
        try installedModels().first { $0.id == id || $0.manifest.modelID == id }
    }

    /// Compares installed source revisions with a catalog without downloading or mutating anything.
    public func checkForUpdates(using catalog: any ModelCatalogProvider) async throws -> [ModelUpdateCandidate] {
        let models = try installedMLXModels()
        var updates: [ModelUpdateCandidate] = []

        for model in models {
            guard let repository = model.manifest.sourceRepository,
                  let currentRevision = model.manifest.sourceRevision,
                  !repository.isEmpty,
                  !currentRevision.isEmpty else { continue }

            let descriptors = try await catalog.search(ModelSearchRequest(query: repository, limit: 100))
            guard let descriptor = descriptors.first(where: { $0.id == repository }),
                  let availableRevision = descriptor.revision,
                  availableRevision != currentRevision else { continue }

            let matchingVariant = descriptor.variants.first {
                $0.runtime == model.manifest.runtime && $0.format == model.manifest.format
            }
            updates.append(ModelUpdateCandidate(
                id: model.id,
                installedModelID: model.id,
                sourceRepository: repository,
                currentRevision: currentRevision,
                availableRevision: availableRevision,
                variant: matchingVariant,
                logoURL: descriptor.logoURL
            ))
        }

        return updates.sorted { $0.id < $1.id }
    }

    public func stagingURL(for variant: ModelVariant) throws -> URL {
        try ensureRoot()
        let stagingDirectory = rootURL.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        return stagingDirectory.appendingPathComponent(safeComponent(variant.id) + ".part")
    }

    public func install(downloadedArtifactAt artifactURL: URL, request: ModelDownloadRequest) throws -> InstalledModel {
        try ensureRoot()
        guard request.variant.format.requiresConversion == false else {
            throw ArchonModelsError.unsupportedArtifact("\(request.variant.format.rawValue) requires conversion before installation.")
        }
        let artifactName = safeArtifactName(preferred: request.variant.name, fallback: artifactURL.lastPathComponent)
        let manifest = ArchonModelManifest(
            variant: request.variant,
            modelName: request.modelName,
            license: request.license,
            logoURL: request.logoURL,
            sourceRepository: request.sourceRepository,
            sourceRevision: request.sourceRevision
        )
        let normalizedManifest = manifest.withArtifactPath(artifactName)
        let validation = ModelManifestValidator.validate(normalizedManifest, artifactAt: artifactURL)
        guard validation.isValid else {
            throw ArchonModelsError.invalidManifest(validation.errors)
        }
        return try install(
            artifactAt: artifactURL,
            manifest: normalizedManifest,
            installationID: request.replacementInstallationID ?? (request.variant.modelID + "-" + request.variant.id)
        )
    }

    private func install(
        artifactAt artifactURL: URL,
        manifest: ArchonModelManifest,
        installationID: String? = nil
    ) throws -> InstalledModel {
        let artifactName = safeArtifactName(preferred: manifest.artifactPath, fallback: artifactURL.lastPathComponent)
        let normalizedManifest = manifest.withArtifactPath(artifactName)
        let directoryName = safeComponent(installationID ?? normalizedManifest.modelID + "-" + artifactName)
        let destination = rootURL.appendingPathComponent(directoryName, isDirectory: true)
        let stagingDirectory = rootURL.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try Task.checkCancellation()
        let destinationArtifact = stagingDirectory.appendingPathComponent(artifactName)
        try FileManager.default.copyItem(at: artifactURL, to: destinationArtifact)
        let manifestURL = stagingDirectory.appendingPathComponent(ArchonModelManifest.filename)
        let manifestData = try JSONEncoder.archonEncoder.encode(normalizedManifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        let backup = rootURL.appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: backup)
        }
        do {
            // Do not cross the atomic commit boundary after a caller has
            // paused or cancelled the owning download task. Once this move
            // succeeds, the new model is intentionally considered installed.
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: stagingDirectory, to: destination)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path), !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }

        return InstalledModel(id: directoryName, directoryURL: destination, manifest: normalizedManifest)
    }

    /// Inspects a user-selected artifact without copying or registering it.
    public func inspectArtifact(at sourceURL: URL) throws -> ModelArtifactInspection {
        try ModelArtifactInspector.inspect(at: sourceURL)
    }

    /// Imports a user-selected artifact. A sidecar manifest is optional for
    /// known runnable formats; raw weights are identified and rejected as
    /// conversion-required rather than being registered as Ready.
    public func importArtifact(at sourceURL: URL, manifest suppliedManifest: ArchonModelManifest? = nil) throws -> InstalledModel {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ArchonModelsError.unsupportedArtifact(sourceURL.path)
        }
        let manifest: ArchonModelManifest
        let artifactURL: URL
        if let suppliedManifest {
            manifest = suppliedManifest
            if let artifactPath = suppliedManifest.artifactPath {
                let components = artifactPath.split(separator: "/", omittingEmptySubsequences: false)
                guard !artifactPath.isEmpty,
                      !artifactPath.hasPrefix("/"),
                      components.count == 1,
                      !components.contains(where: { $0 == "." || $0 == ".." }) else {
                    throw ArchonModelsError.invalidManifest(["artifactPath must be a single safe relative path component."])
                }
                var sourceIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory),
                      sourceIsDirectory.boolValue else {
                    throw ArchonModelsError.invalidManifest(["A manifest artifactPath requires a package directory as the import source."])
                }
                artifactURL = sourceURL.appendingPathComponent(artifactPath, isDirectory: true)
            } else {
                artifactURL = sourceURL
            }
        } else {
            let inspection = try ModelArtifactInspector.inspect(at: sourceURL)
            let modelID = "local/\(safeComponent(sourceURL.deletingPathExtension().lastPathComponent))"
            manifest = inspection.makeManifest(modelID: modelID)
            if let artifactPath = manifest.artifactPath {
                let components = artifactPath.split(separator: "/", omittingEmptySubsequences: false)
                guard !artifactPath.isEmpty,
                      !artifactPath.hasPrefix("/"),
                      components.count == 1,
                      !components.contains(where: { $0 == "." || $0 == ".." }) else {
                    throw ArchonModelsError.invalidManifest(["artifactPath must be a single safe relative path component."])
                }
                artifactURL = sourceURL.appendingPathComponent(artifactPath, isDirectory: true)
            } else {
                artifactURL = sourceURL
            }
        }
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw ArchonModelsError.unsupportedArtifact("Manifest artifact is missing at \(artifactURL.path).")
        }
        if manifest.format.requiresConversion {
            throw ArchonModelsError.unsupportedArtifact("\(manifest.format.rawValue) requires conversion before installation.")
        }
        let artifactName = safeArtifactName(preferred: artifactURL.lastPathComponent, fallback: "model")
        let normalizedManifest = manifest.withArtifactPath(artifactName)
        let validation = ModelManifestValidator.validate(normalizedManifest, artifactAt: artifactURL)
        guard validation.isValid else { throw ArchonModelsError.invalidManifest(validation.errors) }
        return try install(
            artifactAt: artifactURL,
            manifest: normalizedManifest,
            installationID: manifest.modelID + "-" + artifactName
        )
    }

    public func delete(modelID: String) async throws {
        try ensureRoot()
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [(directory: URL, installed: InstalledModel?)] = []
        for directory in entries {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if safeComponent(modelID) == directory.lastPathComponent || modelID == directory.lastPathComponent {
                matches.append((directory, try? installedModelFromDirectory(directory)))
                continue
            }
            let manifestURL = directory.appendingPathComponent(ArchonModelManifest.filename)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ArchonModelManifest.self, from: data) else {
                continue
            }
            if manifest.modelID == modelID {
                matches.append((directory, try? installedModelFromDirectory(directory)))
            }
        }
        for match in matches {
            if let installed = match.installed {
                await loadManager.unload(installed)
            }
            try FileManager.default.removeItem(at: match.directory)
        }
    }

    /// Unloads a resident model before an update replaces its installation.
    public func prepareForReplacement(modelID: String) async throws {
        guard let installed = try installedModel(id: modelID) else { return }
        await loadManager.unload(installed)
    }

    /// Removes only Archon-created staging and backup directories, never installed models.
    public func clearTemporaryStorage() throws {
        try ensureRoot()
        let temporaryPrefixes = [".staging", ".backup-", ".install-"]
        let entries = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [])
        for entry in entries where temporaryPrefixes.contains(where: { entry.lastPathComponent == $0 || entry.lastPathComponent.hasPrefix($0) }) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    public func diskUsageBytes() throws -> Int64 {
        try installedModels().reduce(into: Int64(0)) { total, model in
            total += directorySize(at: model.directoryURL)
        }
    }

    /// Disk usage for the MLX-only user-facing library surfaces.
    public func mlxDiskUsageBytes() throws -> Int64 {
        try installedMLXModels().reduce(into: Int64(0)) { total, model in
            total += directorySize(at: model.directoryURL)
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var managedRootURL = rootURL
        try? managedRootURL.setResourceValues(values)
    }

    private func installedModelFromDirectory(_ directory: URL) throws -> InstalledModel {
        let manifestURL = directory.appendingPathComponent(ArchonModelManifest.filename)
        let decodedManifest = try JSONDecoder().decode(ArchonModelManifest.self, from: Data(contentsOf: manifestURL))
        let manifest = decodedManifest.schemaVersion < ArchonModelManifest.currentSchemaVersion
            ? decodedManifest.withCurrentSchemaVersion()
            : decodedManifest
        let installedAt = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return InstalledModel(id: directory.lastPathComponent, directoryURL: directory, manifest: manifest, installedAt: installedAt)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let item = item as? URL else { return nil }
            return try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        }.reduce(0, +)
    }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(result).prefix(160).isEmpty ? UUID().uuidString : String(String(result).prefix(160))
    }

    private func safeArtifactName(preferred: String?, fallback: String) -> String {
        let candidate = (preferred?.isEmpty == false ? preferred! : fallback)
        return safeComponent(URL(fileURLWithPath: candidate).lastPathComponent)
    }

    private static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (applicationSupport ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Archon", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}

public actor ModelDownloadManager {
    private let byteStreamProvider: ModelByteStreamProvider
    private let tokenStore: (any ModelTokenStore)?
    private let policy: ModelDownloadPolicy
    private let licensePolicy: ModelLicensePolicy?
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: ModelDownloadRequest] = [:]
    private var pausedIDs: Set<String> = []
    private var cancelledIDs: Set<String> = []
    private var backgroundJobs: [String: BackgroundDownloadJob] = [:]

    public init(
        session: URLSession? = nil,
        tokenStore: (any ModelTokenStore)? = KeychainModelTokenStore(),
        policy: ModelDownloadPolicy = ModelDownloadPolicy(),
        licensePolicy: ModelLicensePolicy? = nil,
        byteStreamProvider: ModelByteStreamProvider? = nil
    ) {
        let effectiveSession = session ?? ModelDownloadURLPolicy.makeSession()
        if let byteStreamProvider {
            self.byteStreamProvider = byteStreamProvider
        } else {
            self.byteStreamProvider = { request in
                let (bytes, response) = try await effectiveSession.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ArchonModelsError.invalidResponse
                }
                let stream = AsyncThrowingStream<UInt8, Error> { continuation in
                    let task = Task {
                        do {
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                continuation.yield(byte)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                return (stream, httpResponse)
            }
        }
        self.tokenStore = tokenStore
        self.policy = policy
        self.licensePolicy = licensePolicy
    }

    public func download(
        _ request: ModelDownloadRequest,
        into library: ModelLibrary,
        on device: ArchonDeviceCapabilities = .current
    ) throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        let id = request.variant.id
        guard activeTasks[id] == nil else { throw ArchonModelsError.downloadInProgress(id) }
        guard request.variant.downloadURL != nil ||
            !request.variant.resources.isEmpty ||
            !request.variant.tokenizerResources.isEmpty else {
            throw ArchonModelsError.noDownloadURL
        }
        try validateDownloadCompatibility(request.variant, on: device)

        pausedIDs.remove(id)
        cancelledIDs.remove(id)
        requests[id] = request
        let (stream, continuation) = AsyncThrowingStream<ModelDownloadEvent, Error>.makeStream()
        continuation.yield(ModelDownloadEvent(variantID: id, state: .queued))
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.run(request: request, library: library, device: device, continuation: continuation)
        }
        activeTasks[id] = task
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.cancel(variantID: id)
            }
        }
        return stream
    }

    /// Runs the complete model-library lifecycle on top of an OS-managed
    /// background transfer coordinator. Each resource is transferred to the
    /// same staging layout used by the foreground manager; verification and
    /// atomic installation remain mandatory before `.ready` is emitted.
    public func downloadInBackground(
        _ request: ModelDownloadRequest,
        into library: ModelLibrary,
        using coordinator: ModelBackgroundTransferCoordinator,
        on device: ArchonDeviceCapabilities = .current
    ) throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        let id = request.variant.id
        guard activeTasks[id] == nil else { throw ArchonModelsError.downloadInProgress(id) }
        guard request.variant.downloadURL != nil ||
            !request.variant.resources.isEmpty ||
            !request.variant.tokenizerResources.isEmpty else {
            throw ArchonModelsError.noDownloadURL
        }
        try validateDownloadCompatibility(request.variant, on: device)

        pausedIDs.remove(id)
        cancelledIDs.remove(id)
        requests[id] = request
        backgroundJobs[id] = BackgroundDownloadJob(coordinator: coordinator, transferIdentifiers: [])
        let (stream, continuation) = AsyncThrowingStream<ModelDownloadEvent, Error>.makeStream()
        continuation.yield(ModelDownloadEvent(variantID: id, state: .queued))
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.runInBackground(request: request, library: library, device: device, continuation: continuation, coordinator: coordinator)
        }
        activeTasks[id] = task
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.cancel(variantID: id)
            }
        }
        return stream
    }

    public func pause(variantID: String) {
        guard activeTasks[variantID] != nil else { return }
        pausedIDs.insert(variantID)
        if let job = backgroundJobs[variantID] {
            let coordinator = job.coordinator
            let transferIdentifiers = job.transferIdentifiers
            Task {
                for transferIdentifier in transferIdentifiers {
                    try? await coordinator.pause(identifier: transferIdentifier)
                }
            }
            return
        }
        activeTasks[variantID]?.cancel()
    }

    public func resume(
        variantID: String,
        into library: ModelLibrary,
        on device: ArchonDeviceCapabilities = .current
    ) throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        guard let request = requests[variantID] else { throw ArchonModelsError.invalidModelIdentifier(variantID) }
        return try download(request, into: library, on: device)
    }

    /// Resumes a background-library transfer after a host recreated its
    /// coordinator. The coordinator reconnects to any OS-owned tasks before
    /// this manager resumes verification and installation.
    public func resumeInBackground(
        variantID: String,
        into library: ModelLibrary,
        using coordinator: ModelBackgroundTransferCoordinator,
        on device: ArchonDeviceCapabilities = .current
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        try await resumeInBackground(
            variantID: variantID,
            request: nil,
            into: library,
            using: coordinator,
            on: device
        )
    }

    /// Resumes a background-library transfer after a host recreated both the
    /// coordinator and this manager. The coordinator persists only the
    /// transport request; the consuming app must reconstruct the richer model
    /// request from its catalog or app-owned metadata before verification and
    /// installation can continue.
    public func resumeInBackground(
        variantID: String,
        request reconstructedRequest: ModelDownloadRequest,
        into library: ModelLibrary,
        using coordinator: ModelBackgroundTransferCoordinator,
        on device: ArchonDeviceCapabilities = .current
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        guard reconstructedRequest.variant.id == variantID else {
            throw ArchonModelsError.invalidModelIdentifier(variantID)
        }
        requests[variantID] = reconstructedRequest
        return try await resumeInBackground(
            variantID: variantID,
            request: reconstructedRequest,
            into: library,
            using: coordinator,
            on: device
        )
    }

    private func resumeInBackground(
        variantID: String,
        request reconstructedRequest: ModelDownloadRequest?,
        into library: ModelLibrary,
        using coordinator: ModelBackgroundTransferCoordinator,
        on device: ArchonDeviceCapabilities
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        if let reconstructedRequest {
            guard reconstructedRequest.variant.id == variantID else {
                throw ArchonModelsError.invalidModelIdentifier(variantID)
            }
            requests[variantID] = reconstructedRequest
        }
        guard let request = requests[variantID] else {
            throw ArchonModelsError.invalidModelIdentifier(variantID)
        }
        _ = try await coordinator.reconnect()
        return try downloadInBackground(request, into: library, using: coordinator, on: device)
    }

    /// Retries the last request, preserving any valid partial file for range resume.
    public func retry(
        variantID: String,
        into library: ModelLibrary,
        backoff: TimeInterval = 0,
        on device: ArchonDeviceCapabilities = .current
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        guard let request = requests[variantID] else { throw ArchonModelsError.invalidModelIdentifier(variantID) }
        if backoff > 0 {
            let bounded = min(backoff, 60)
            try await Task.sleep(for: .seconds(bounded))
        }
        return try download(request, into: library, on: device)
    }

    /// Retries from an empty staging location, leaving the installed model untouched.
    public func redownload(
        variantID: String,
        into library: ModelLibrary,
        on device: ArchonDeviceCapabilities = .current
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        guard let request = requests[variantID] else { throw ArchonModelsError.invalidModelIdentifier(variantID) }
        let stagingURL = try await library.stagingURL(for: request.variant)
        try? FileManager.default.removeItem(at: stagingURL)
        return try download(request, into: library, on: device)
    }

    /// Downloads the available catalog variant for an installed model's explicit update candidate.
    public func update(
        _ candidate: ModelUpdateCandidate,
        into library: ModelLibrary,
        on device: ArchonDeviceCapabilities = .current
    ) async throws -> AsyncThrowingStream<ModelDownloadEvent, Error> {
        guard let variant = candidate.variant else {
            throw ArchonModelsError.updateUnavailable(candidate.sourceRepository)
        }
        guard let installed = try await library.installedModel(id: candidate.installedModelID) else {
            throw ArchonModelsError.updateUnavailable(candidate.installedModelID)
        }
        try await library.prepareForReplacement(modelID: installed.id)
        let request = ModelDownloadRequest(
            variant: variant,
            modelName: installed.manifest.modelName,
            license: installed.manifest.license,
            logoURL: candidate.logoURL ?? installed.manifest.logoURL,
            sourceRepository: candidate.sourceRepository,
            sourceRevision: candidate.availableRevision,
            replacementInstallationID: installed.id
        )
        return try download(request, into: library, on: device)
    }

    public func cancel(variantID: String) {
        guard activeTasks[variantID] != nil else { return }
        cancelledIDs.insert(variantID)
        if let job = backgroundJobs[variantID] {
            let coordinator = job.coordinator
            let transferIdentifiers = job.transferIdentifiers
            Task {
                for transferIdentifier in transferIdentifiers {
                    try? await coordinator.cancel(identifier: transferIdentifier)
                }
            }
            return
        }
        activeTasks[variantID]?.cancel()
    }

    public func isDownloading(variantID: String) -> Bool {
        activeTasks[variantID] != nil
    }

    private func run(
        request: ModelDownloadRequest,
        library: ModelLibrary,
        device: ArchonDeviceCapabilities,
        continuation: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation
    ) async {
        let id = request.variant.id
        defer { activeTasks[id] = nil }

        do {
            continuation.yield(ModelDownloadEvent(variantID: id, state: .resolving))
            let stagingURL = try await library.stagingURL(for: request.variant)
            if let licensePolicy {
                let identifier = request.license?.identifier ?? "unknown"
                switch licensePolicy.decision(for: request.license) {
                case .allowed:
                    break
                case .confirmationRequired:
                    throw ArchonModelsError.licenseConfirmationRequired(identifier)
                case .denied:
                    throw ArchonModelsError.licenseDenied(identifier)
                }
            }
            if request.variant.source == .huggingFace,
               request.variant.requiresAuthentication,
               await tokenStore?.token(for: "huggingface.co") == nil {
                throw ArchonModelsError.authenticationRequired("huggingface.co")
            }
            try validateDownloadCompatibility(request.variant, on: device)

            let pending = try pendingDownloads(for: request.variant)
            let existingBytes = pending.reduce(into: Int64(0)) { total, item in
                let target = item.relativePath.map { stagingURL.appendingPathComponent($0) } ?? stagingURL
                total += fileSize(at: target)
            }
            let expectedTotal = request.variant.sizeBytes ?? pending.compactMap(\.expectedSize).reduceIfComplete()
            if let expectedTotal,
               let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: library.rootURL.path),
               let freeBytes = (fileSystemAttributes[.systemFreeSize] as? NSNumber)?.int64Value,
               max(expectedTotal - existingBytes, 0) > freeBytes {
                throw ArchonModelsError.insufficientDiskSpace
            }
            if let expectedTotal, expectedTotal > policy.maximumDownloadBytes {
                throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
            }
            if existingBytes > policy.maximumDownloadBytes {
                throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
            }

            let authorizationToken = request.variant.source == .huggingFace
                ? await tokenStore?.token(for: "huggingface.co")
                : nil
            var downloadedBytes = existingBytes
            for item in pending {
                try Task.checkCancellation()
                let targetURL = item.relativePath.map { stagingURL.appendingPathComponent($0) } ?? stagingURL
                let previousFileBytes = fileSize(at: targetURL)
                let completed = try await downloadSingleWithRetry(
                    item,
                    to: targetURL,
                    completedBytesBeforeFile: downloadedBytes - fileSize(at: targetURL),
                    totalBytes: expectedTotal,
                    authorizationToken: authorizationToken,
                    variantID: id,
                    continuation: continuation
                )
                downloadedBytes += completed - previousFileBytes
            }

            try Task.checkCancellation()
            if let expectedSize = request.variant.sizeBytes, expectedSize != downloadedBytes {
                throw ArchonModelsError.sizeMismatch(expected: expectedSize, actual: downloadedBytes)
            }

            try Task.checkCancellation()
            continuation.yield(ModelDownloadEvent(variantID: id, state: .verifying))
            if pending.count == 1, let expectedChecksum = request.variant.sha256 {
                let actualChecksum = try sha256(of: stagingURL)
                guard expectedChecksum.lowercased() == actualChecksum.lowercased() else {
                    throw ArchonModelsError.integrityCheckFailed(expected: expectedChecksum, actual: actualChecksum)
                }
            }

            try Task.checkCancellation()
            continuation.yield(ModelDownloadEvent(variantID: id, state: .installing))
            let installed = try await library.install(downloadedArtifactAt: stagingURL, request: request)
            try? FileManager.default.removeItem(at: stagingURL)
            continuation.yield(ModelDownloadEvent(variantID: id, state: .ready(installed)))
            continuation.finish()
        } catch {
            if Task.isCancelled || error is CancellationError {
                if pausedIDs.contains(id) {
                    continuation.yield(ModelDownloadEvent(variantID: id, state: .paused))
                    continuation.finish()
                    return
                }
                if cancelledIDs.contains(id), let url = try? await library.stagingURL(for: request.variant) {
                    try? FileManager.default.removeItem(at: url)
                }
                continuation.yield(ModelDownloadEvent(variantID: id, state: .cancelled))
                continuation.finish(throwing: ArchonModelsError.cancelled)
            } else {
                continuation.yield(ModelDownloadEvent(variantID: id, state: .failed(error.localizedDescription)))
                continuation.finish(throwing: error)
            }
        }
    }

    private func runInBackground(
        request: ModelDownloadRequest,
        library: ModelLibrary,
        device: ArchonDeviceCapabilities,
        continuation: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation,
        coordinator: ModelBackgroundTransferCoordinator
    ) async {
        let id = request.variant.id
        defer {
            activeTasks[id] = nil
            backgroundJobs[id] = nil
        }

        do {
            continuation.yield(ModelDownloadEvent(variantID: id, state: .resolving))
            try await coordinator.bindDestinationRoot(library.rootURL)
            if let licensePolicy {
                let identifier = request.license?.identifier ?? "unknown"
                switch licensePolicy.decision(for: request.license) {
                case .allowed:
                    break
                case .confirmationRequired:
                    throw ArchonModelsError.licenseConfirmationRequired(identifier)
                case .denied:
                    throw ArchonModelsError.licenseDenied(identifier)
                }
            }
            if request.variant.source == .huggingFace,
               request.variant.requiresAuthentication,
               await tokenStore?.token(for: "huggingface.co") == nil {
                throw ArchonModelsError.authenticationRequired("huggingface.co")
            }
            try validateDownloadCompatibility(request.variant, on: device)

            let stagingURL = try await library.stagingURL(for: request.variant)
            let pending = try pendingDownloads(for: request.variant)
            // Background URLSession moves completed files into the staging
            // layout atomically. Count completed resources as they are
            // observed below rather than treating arbitrary staging files as
            // trusted progress.
            let existingBytes: Int64 = 0
            let expectedTotal = request.variant.sizeBytes ?? pending.compactMap(\.expectedSize).reduceIfComplete()
            if let expectedTotal, expectedTotal > policy.maximumDownloadBytes {
                throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
            }
            if let expectedTotal,
               let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: library.rootURL.path),
               let freeBytes = (fileSystemAttributes[.systemFreeSize] as? NSNumber)?.int64Value,
               max(expectedTotal - existingBytes, 0) > freeBytes {
                throw ArchonModelsError.insufficientDiskSpace
            }

            let authorizationToken = request.variant.source == .huggingFace
                ? await tokenStore?.token(for: "huggingface.co")
                : nil
            var completedBytes = existingBytes
            for (index, item) in pending.enumerated() {
                try Task.checkCancellation()
                if pausedIDs.contains(id) {
                    continuation.yield(ModelDownloadEvent(variantID: id, state: .paused))
                    continuation.finish()
                    return
                }
                if cancelledIDs.contains(id) {
                    try? FileManager.default.removeItem(at: stagingURL)
                    continuation.yield(ModelDownloadEvent(variantID: id, state: .cancelled))
                    continuation.finish(throwing: ArchonModelsError.cancelled)
                    return
                }

                let targetURL = item.relativePath.map { stagingURL.appendingPathComponent($0) } ?? stagingURL
                let transferIdentifier = "\(id)#\(index)"
                registerBackgroundTransfer(variantID: id, transferIdentifier: transferIdentifier)
                let transferRequest = ModelBackgroundDownloadRequest(
                    identifier: transferIdentifier,
                    url: item.url,
                    destinationURL: targetURL,
                    headers: authorizationToken.map { ["Authorization": "Bearer \($0)"] } ?? [:]
                )

                let transferRecord = try await coordinator.record(for: transferIdentifier)
                let transferEvents: AsyncThrowingStream<ModelBackgroundTransferEvent, Error>
                if let transferRecord,
                   transferRecord.status == .ready,
                   FileManager.default.fileExists(atPath: targetURL.path) {
                    completedBytes += fileSize(at: targetURL)
                    continue
                } else if let transferRecord,
                          transferRecord.status == .downloading,
                          await coordinator.isActive(identifier: transferIdentifier) {
                    transferEvents = try await coordinator.events(for: transferIdentifier)
                } else if let transferRecord,
                          transferRecord.status == .paused || transferRecord.status == .failed || transferRecord.status == .cancelled {
                    transferEvents = try await coordinator.resume(identifier: transferIdentifier, request: transferRequest)
                } else {
                    transferEvents = try await coordinator.start(transferRequest)
                }

                var ready = false
                for try await event in transferEvents {
                    switch event.state {
                    case .queued:
                        continuation.yield(ModelDownloadEvent(variantID: id, state: .resolving))
                    case .downloading(let bytesDownloaded, let totalBytes):
                        let aggregate = completedBytes + bytesDownloaded
                        if aggregate > policy.maximumDownloadBytes {
                            throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
                        }
                        let progress = expectedTotal.map { min(1, Double(aggregate) / Double(max($0, 1))) } ?? 0
                        continuation.yield(ModelDownloadEvent(variantID: id, state: .downloading(
                            progress: progress,
                            bytesDownloaded: aggregate,
                            totalBytes: expectedTotal ?? totalBytes.map { $0 + completedBytes }
                        )))
                    case .ready:
                        ready = true
                    case .paused:
                        if pausedIDs.contains(id) {
                            continuation.yield(ModelDownloadEvent(variantID: id, state: .paused))
                            continuation.finish()
                            return
                        }
                        throw ArchonModelsError.backgroundTransferFailed("Transfer paused unexpectedly.")
                    case .cancelled:
                        if cancelledIDs.contains(id) {
                            try? FileManager.default.removeItem(at: stagingURL)
                            continuation.yield(ModelDownloadEvent(variantID: id, state: .cancelled))
                            continuation.finish(throwing: ArchonModelsError.cancelled)
                            return
                        }
                        throw ArchonModelsError.backgroundTransferFailed("Transfer was cancelled unexpectedly.")
                    case .failed(let message):
                        throw ArchonModelsError.backgroundTransferFailed(message)
                    }
                }
                guard ready, FileManager.default.fileExists(atPath: targetURL.path) else {
                    throw ArchonModelsError.backgroundTransferFailed("Transfer completed without its staged artifact.")
                }
                completedBytes += fileSize(at: targetURL)
                if completedBytes > policy.maximumDownloadBytes {
                    throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
                }
            }

            try Task.checkCancellation()
            if let expectedSize = request.variant.sizeBytes, expectedSize != completedBytes {
                throw ArchonModelsError.sizeMismatch(expected: expectedSize, actual: completedBytes)
            }
            try Task.checkCancellation()
            continuation.yield(ModelDownloadEvent(variantID: id, state: .verifying))
            if pending.count == 1, let expectedChecksum = request.variant.sha256 {
                let actualChecksum = try sha256(of: stagingURL)
                guard expectedChecksum.lowercased() == actualChecksum.lowercased() else {
                    throw ArchonModelsError.integrityCheckFailed(expected: expectedChecksum, actual: actualChecksum)
                }
            }
            try Task.checkCancellation()
            continuation.yield(ModelDownloadEvent(variantID: id, state: .installing))
            let installed = try await library.install(downloadedArtifactAt: stagingURL, request: request)
            try? FileManager.default.removeItem(at: stagingURL)
            continuation.yield(ModelDownloadEvent(variantID: id, state: .ready(installed)))
            continuation.finish()
        } catch {
            if pausedIDs.contains(id) {
                continuation.yield(ModelDownloadEvent(variantID: id, state: .paused))
                continuation.finish()
            } else if cancelledIDs.contains(id) {
                if let url = try? await library.stagingURL(for: request.variant) {
                    try? FileManager.default.removeItem(at: url)
                }
                continuation.yield(ModelDownloadEvent(variantID: id, state: .cancelled))
                continuation.finish(throwing: ArchonModelsError.cancelled)
            } else {
                continuation.yield(ModelDownloadEvent(variantID: id, state: .failed(error.localizedDescription)))
                continuation.finish(throwing: error)
            }
        }
    }

    private func registerBackgroundTransfer(variantID: String, transferIdentifier: String) {
        guard var job = backgroundJobs[variantID] else { return }
        if !job.transferIdentifiers.contains(transferIdentifier) {
            job.transferIdentifiers.append(transferIdentifier)
            backgroundJobs[variantID] = job
        }
    }

    /// Applies the same device/runtime contract used by model search and load
    /// before a transfer is allowed to start. Downloading a model does not
    /// allocate its inference buffers, but refusing an artifact that cannot
    /// load avoids spending bandwidth and disk space on an unusable install.
    private func validateDownloadCompatibility(
        _ variant: ModelVariant,
        on device: ArchonDeviceCapabilities
    ) throws {
        let compatibility = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)
        guard compatibility.canLoad else {
            throw ArchonModelsError.incompatible(compatibility.status)
        }
    }

    private func pendingDownloads(for variant: ModelVariant) throws -> [PendingModelDownload] {
        if variant.resources.isEmpty && variant.tokenizerResources.isEmpty {
            guard let url = variant.downloadURL else { throw ArchonModelsError.noDownloadURL }
            try ModelDownloadURLPolicy.validate(url)
            return [PendingModelDownload(url: url, relativePath: nil, expectedSize: variant.sizeBytes, checksum: variant.sha256)]
        }

        var pending: [PendingModelDownload] = []
        var paths = Set<String>()
        for resource in variant.resources + variant.tokenizerResources {
            guard isSafeRelativePath(resource.relativePath) else {
                throw ArchonModelsError.invalidManifest(["Resource path is unsafe: \(resource.relativePath)"])
            }
            guard let url = resource.url else {
                throw ArchonModelsError.noDownloadURL
            }
            try ModelDownloadURLPolicy.validate(url)
            guard paths.insert(resource.relativePath).inserted else {
                throw ArchonModelsError.invalidManifest(["Resource path is duplicated: \(resource.relativePath)"])
            }
            pending.append(PendingModelDownload(
                url: url,
                relativePath: resource.relativePath,
                expectedSize: resource.sizeBytes,
                checksum: resource.sha256
            ))
        }

        // A package may expose a primary download URL in addition to resources.
        // Keep it in the package when the resource list does not already name it.
        if let url = variant.downloadURL,
           let filename = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/").last.map(String.init),
           isSafeRelativePath(filename),
           !paths.contains(filename) {
            try ModelDownloadURLPolicy.validate(url)
            pending.insert(PendingModelDownload(url: url, relativePath: filename, expectedSize: nil, checksum: nil), at: 0)
        }
        guard !pending.isEmpty else { throw ArchonModelsError.noDownloadURL }
        return pending
    }

    private func downloadSingle(
        _ pending: PendingModelDownload,
        to targetURL: URL,
        completedBytesBeforeFile: Int64,
        totalBytes: Int64?,
        authorizationToken: String?,
        variantID: String,
        continuation: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation
    ) async throws -> Int64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var currentBytes = fileSize(at: targetURL)

        // A pause can happen after a resource has completed but before the
        // package task advances to the next resource. Avoid asking a server
        // for an invalid Range starting exactly at EOF; verify the local file
        // and resume from the next incomplete resource instead.
        if let expectedSize = pending.expectedSize, currentBytes == expectedSize {
            if let expectedChecksum = pending.checksum {
                let actualChecksum = try sha256(of: targetURL)
                if expectedChecksum.lowercased() == actualChecksum.lowercased() {
                    return currentBytes
                }
            } else {
                return currentBytes
            }
            try handleRemoval(of: targetURL)
            currentBytes = 0
        } else if let expectedSize = pending.expectedSize, currentBytes > expectedSize {
            try handleRemoval(of: targetURL)
            currentBytes = 0
        }

        guard completedBytesBeforeFile >= 0,
              completedBytesBeforeFile + currentBytes <= policy.maximumDownloadBytes else {
            throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
        }

        var request = URLRequest(url: pending.url)
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        if currentBytes > 0 {
            request.setValue("bytes=\(currentBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await byteStreamProvider(request)
        guard (200...299).contains(response.statusCode) else {
            throw ArchonModelsError.httpFailure(statusCode: response.statusCode)
        }

        // Some servers ignore Range. Never append a full 200 response to a
        // partial file or the resulting artifact will fail closed at validation.
        let isResumed = currentBytes > 0 && response.statusCode == 206
        if isResumed {
            guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                  contentRangeStart(contentRange) == currentBytes else {
                throw ArchonModelsError.invalidResponse
            }
        }
        if !fileManager.fileExists(atPath: targetURL.path) {
            fileManager.createFile(atPath: targetURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: targetURL) else { throw ArchonModelsError.invalidResponse }
        if !isResumed {
            currentBytes = 0
            try handle.truncate(atOffset: 0)
        }
        try handle.seekToEnd()
        let responseLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let responseLength,
           completedBytesBeforeFile + currentBytes + responseLength > policy.maximumDownloadBytes {
            throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
        }
        let inferredTotal = totalBytes ?? responseLength.map { $0 + completedBytesBeforeFile + currentBytes }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var reportedBytes = currentBytes

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if completedBytesBeforeFile + reportedBytes + Int64(buffer.count) > policy.maximumDownloadBytes {
                    throw ArchonModelsError.downloadSizeExceeded(maximum: policy.maximumDownloadBytes)
                }
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    reportedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let aggregate = completedBytesBeforeFile + reportedBytes
                    let progress = inferredTotal.map { min(1, Double(aggregate) / Double(max($0, 1))) } ?? 0
                    continuation.yield(ModelDownloadEvent(variantID: variantID, state: .downloading(progress: progress, bytesDownloaded: aggregate, totalBytes: inferredTotal)))
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                reportedBytes += Int64(buffer.count)
            }
            try handle.close()

            let aggregate = completedBytesBeforeFile + reportedBytes
            let progress = inferredTotal.map { min(1, Double(aggregate) / Double(max($0, 1))) } ?? 0
            continuation.yield(ModelDownloadEvent(variantID: variantID, state: .downloading(
                progress: progress,
                bytesDownloaded: aggregate,
                totalBytes: inferredTotal
            )))
        } catch {
            try? handle.close()
            throw error
        }

        if let expectedSize = pending.expectedSize, expectedSize != reportedBytes {
            throw ArchonModelsError.sizeMismatch(expected: expectedSize, actual: reportedBytes)
        }
        if let expectedChecksum = pending.checksum {
            let actualChecksum = try sha256(of: targetURL)
            guard expectedChecksum.lowercased() == actualChecksum.lowercased() else {
                throw ArchonModelsError.integrityCheckFailed(expected: expectedChecksum, actual: actualChecksum)
            }
        }
        return reportedBytes
    }

    private func downloadSingleWithRetry(
        _ pending: PendingModelDownload,
        to targetURL: URL,
        completedBytesBeforeFile: Int64,
        totalBytes: Int64?,
        authorizationToken: String?,
        variantID: String,
        continuation: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation
    ) async throws -> Int64 {
        var attempt = 0
        while true {
            do {
                return try await downloadSingle(
                    pending,
                    to: targetURL,
                    completedBytesBeforeFile: completedBytesBeforeFile,
                    totalBytes: totalBytes,
                    authorizationToken: authorizationToken,
                    variantID: variantID,
                    continuation: continuation
                )
            } catch {
                attempt += 1
                guard attempt < policy.maxAttempts,
                      shouldRetry(error),
                      !Task.isCancelled else {
                    throw error
                }
                let exponent = pow(2, Double(attempt - 1))
                let delay = min(policy.maximumBackoff, policy.initialBackoff * exponent)
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ArchonModelsError.invalidResponse }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return false }
        if let error = error as? URLError { return error.code != .cancelled }
        if case let ArchonModelsError.httpFailure(statusCode) = error {
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
        }
        return false
    }

    private func contentRangeStart(_ value: String) -> Int64? {
        let components = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }
        guard let range = components[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        return Int64(range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }

    private func handleRemoval(of url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private extension Array where Element == Int64 {
    func reduceIfComplete() -> Int64? {
        isEmpty ? nil : reduce(0, +)
    }
}

private extension JSONEncoder {
    static var archonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
