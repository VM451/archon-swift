import SwiftUI
import ArchonCore
import ArchonModels

/// A read-only, source-linked model detail screen. The optional selection
/// closure is supplied by the host so the view never presents a dead action.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct ModelDetailView: View {
    public let model: ModelDescriptor
    private let deviceOverride: ArchonDeviceCapabilities?
    private let onSelectVariant: ((ModelVariant) -> Void)?
    private let library: ModelLibrary
    private let downloadManager: ModelDownloadManager
    @State private var phases: [String: ModelDetailDownloadPhase] = [:]
    @State private var progress: [String: Double] = [:]
    @State private var statuses: [String: String] = [:]
    @State private var installedModels: [InstalledModel] = []
    @State private var errorMessage: String?

    public init(
        model: ModelDescriptor,
        device: ArchonDeviceCapabilities? = nil,
        onSelectVariant: ((ModelVariant) -> Void)? = nil,
        library: ModelLibrary = .makeDefault(),
        downloadManager: ModelDownloadManager = ModelDownloadManager()
    ) {
        self.model = model
        self.deviceOverride = device
        self.onSelectVariant = onSelectVariant
        self.library = library
        self.downloadManager = downloadManager
    }

    public var body: some View {
        List {
            Section("Overview") {
                ModelLogoView(model: model, size: 64)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LabeledContent("Publisher", value: model.publisher)
                if let family = model.family {
                    LabeledContent("Family", value: family)
                }
                if let architecture = model.architecture {
                    LabeledContent("Architecture", value: architecture)
                }
                if let parameters = model.parameterCount {
                    LabeledContent("Parameters", value: parameters.formatted())
                }
                if let revision = model.revision {
                    LabeledContent("Revision", value: revision)
                }
                LabeledContent("Source", value: model.source.displayName)
                if !model.tasks.isEmpty {
                    LabeledContent("Capabilities", value: model.tasks.map(\.displayName).sorted().joined(separator: ", "))
                }
                if let description = model.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }

            Section("MLX Variants") {
                if mlxVariants.isEmpty {
                    ContentUnavailableView(
                        "MLX Variant Unavailable",
                        systemImage: "shippingbox",
                        description: Text("This model is not published as a directly runnable MLX artifact.")
                    )
                }
                ForEach(mlxVariants) { variant in
                    let compatibility = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(variant.name)
                                .font(.headline)
                            Spacer()
                            Text(compatibility.status.displayName)
                                .font(.caption)
                                .foregroundStyle(compatibility.canLoad ? .green : .secondary)
                        }

                        Text(variantSummary(variant, compatibility: compatibility))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let quality = variant.estimatedQualityScore {
                            LabeledContent("Estimated quality", value: quality.formatted(.number.precision(.fractionLength(2))))
                                .font(.caption)
                        }
                        if let speed = variant.estimatedTokensPerSecond {
                            LabeledContent("Estimated speed", value: "~\(speed.formatted(.number.precision(.fractionLength(1)))) tokens/sec")
                                .font(.caption)
                        }

                        if let status = statuses[variant.id] {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let value = progress[variant.id] {
                            ProgressView(value: value)
                        }

                        variantActions(variant, compatibility: compatibility)

                        if let reason = compatibility.reasons.first {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let license = model.license {
                Section("License") {
                    if let identifier = license.identifier, !identifier.isEmpty {
                        LabeledContent("Identifier", value: identifier)
                    }
                    if let url = license.url {
                        Link("View license", destination: url)
                    }
                }
            }

            if let sourceURL = model.sourceURL {
                Section {
                    Link("Open model source", destination: sourceURL)
                }
            }

            if mlxVariants.contains(where: \.isExperimental) {
                Section("Experimental") {
                    Text("This export is Experimental until runtime, output, and device validation have passed. It cannot be selected for local inference yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(model.name)
        .task {
            await refreshInstalledModels()
        }
        .alert("Model Detail", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The model operation failed.")
        }
    }

    private var device: ArchonDeviceCapabilities {
        deviceOverride ?? .current
    }

    private var mlxVariants: [ModelVariant] {
        model.variants.filter { $0.runtime == .mlx && $0.format == .mlx }
    }

    @ViewBuilder
    private func variantActions(_ variant: ModelVariant, compatibility: ModelCompatibility) -> some View {
        let installed = installedModel(for: variant)
        HStack {
            switch phases[variant.id] {
            case .downloading:
                Button("Pause") { pause(variantID: variant.id) }
                Button("Cancel", role: .cancel) { cancel(variantID: variant.id) }
            case .paused:
                Button("Resume") { resume(variant) }
                Button("Cancel", role: .cancel) { cancel(variantID: variant.id) }
            case .failed, .cancelled:
                Button("Retry") { retry(variant) }
            case .ready:
                Button("Redownload") { redownload(variant) }
            default:
                if installed == nil {
                    Button(
                        compatibility.canLoad ? "Download" :
                            compatibility.status == .conversionRequired ? "Conversion required" : "Unavailable"
                    ) {
                        beginDownload(variant)
                    }
                    .disabled(
                        !compatibility.canLoad ||
                        (variant.downloadURL == nil && variant.resources.isEmpty && variant.tokenizerResources.isEmpty)
                    )
                } else {
                    Button("Redownload") { redownload(variant) }
                }
            }

            if let installed {
                Button("Delete", role: .destructive) {
                    delete(installed)
                }
            }

            if let onSelectVariant, compatibility.canLoad, installed != nil {
                Button("Use Model") {
                    onSelectVariant(variant)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func installedModel(for variant: ModelVariant) -> InstalledModel? {
        installedModels.first {
            $0.manifest.modelID == variant.modelID &&
            $0.manifest.runtime == variant.runtime &&
            $0.manifest.format == variant.format
        }
    }

    @MainActor
    private func refreshInstalledModels() async {
        do {
            installedModels = try await library.installedMLXModels()
            errorMessage = nil
        } catch {
            if !error.isCancellation && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func beginDownload(_ variant: ModelVariant) {
        guard variant.runtime == .mlx, variant.format == .mlx else {
            errorMessage = "Only MLX model variants can be downloaded through the user-facing model library."
            return
        }
        start(
            variant: variant,
            operation: {
                try await downloadManager.download(
                    ModelDownloadRequest(
                        variant: variant,
                        modelName: model.name,
                        license: model.license,
                        logoURL: model.logoURL,
                        sourceRepository: model.id,
                        sourceRevision: model.revision
                    ),
                    into: library,
                    on: device
                )
            }
        )
    }

    @MainActor
    private func pause(variantID: String) {
        Task { @MainActor in
            await downloadManager.pause(variantID: variantID)
            phases[variantID] = .paused
            statuses[variantID] = "Paused"
        }
    }

    @MainActor
    private func cancel(variantID: String) {
        Task { @MainActor in
            await downloadManager.cancel(variantID: variantID)
            phases[variantID] = .cancelled
            statuses[variantID] = "Cancelled"
        }
    }

    @MainActor
    private func resume(_ variant: ModelVariant) {
        start(variant: variant) {
            try await downloadManager.resume(variantID: variant.id, into: library, on: device)
        }
    }

    @MainActor
    private func retry(_ variant: ModelVariant) {
        start(variant: variant) {
            try await downloadManager.retry(variantID: variant.id, into: library, on: device)
        }
    }

    @MainActor
    private func redownload(_ variant: ModelVariant) {
        start(variant: variant) {
            try await downloadManager.redownload(variantID: variant.id, into: library, on: device)
        }
    }

    @MainActor
    private func delete(_ installed: InstalledModel) {
        Task { @MainActor in
            do {
                try await library.delete(modelID: installed.id)
                await refreshInstalledModels()
            } catch {
                if !error.isCancellation && !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func start(
        variant: ModelVariant,
        operation: @escaping @Sendable () async throws -> AsyncThrowingStream<ModelDownloadEvent, Error>
    ) {
        phases[variant.id] = .queued
        statuses[variant.id] = "Queued"
        Task { @MainActor in
            do {
                let stream = try await operation()
                for try await event in stream {
                    switch event.state {
                    case .queued:
                        phases[variant.id] = .queued
                        statuses[variant.id] = "Queued"
                    case .resolving:
                        phases[variant.id] = .resolving
                        statuses[variant.id] = "Resolving"
                    case .downloading(let value, _, _):
                        phases[variant.id] = .downloading
                        progress[variant.id] = value
                        statuses[variant.id] = "Downloading"
                    case .paused:
                        phases[variant.id] = .paused
                        statuses[variant.id] = "Paused"
                    case .verifying:
                        phases[variant.id] = .verifying
                        statuses[variant.id] = "Verifying"
                    case .installing:
                        phases[variant.id] = .installing
                        statuses[variant.id] = "Installing"
                    case .ready:
                        phases[variant.id] = .ready
                        progress[variant.id] = 1
                        statuses[variant.id] = "Ready"
                        await refreshInstalledModels()
                    case .updateAvailable:
                        phases[variant.id] = .updateAvailable
                        statuses[variant.id] = "Update available"
                    case .failed(let message):
                        phases[variant.id] = .failed
                        statuses[variant.id] = message
                    case .cancelled:
                        phases[variant.id] = .cancelled
                        statuses[variant.id] = "Cancelled"
                    }
                }
            } catch {
                if !error.isCancellation && !Task.isCancelled {
                    phases[variant.id] = .failed
                    statuses[variant.id] = error.localizedDescription
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func variantSummary(_ variant: ModelVariant, compatibility: ModelCompatibility) -> String {
        var values = [variant.runtime.rawValue, variant.format.rawValue, compatibility.fit.rawValue]
        if let size = variant.sizeBytes {
            values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let memory = ModelCompatibilityAnalyzer.estimatedPeakMemoryBytes(for: variant) {
            values.append("Predicted peak RAM " + ByteCountFormatter.string(
                fromByteCount: Int64(min(memory, UInt64(Int64.max))),
                countStyle: .memory
            ))
        } else if variant.runtime == .mlx {
            values.append("Peak RAM estimate unavailable")
        }
        if let contextLength = variant.contextLength {
            values.append("Context \(contextLength.formatted())")
        }
        if let precision = variant.precision ?? variant.quantization {
            values.append(precision)
        }
        if !variant.capabilities.tasks.isEmpty {
            values.append(variant.capabilities.tasks.map(\.displayName).sorted().joined(separator: ", "))
        }
        return values.joined(separator: " · ")
    }
}

private enum ModelDetailDownloadPhase {
    case queued, resolving, downloading, paused, verifying, installing
    case ready, updateAvailable, failed, cancelled
}

private extension ArchonModelSource {
    var displayName: String {
        switch self {
        case .appleCoreAI: "Apple Core AI"
        case .huggingFace: "Hugging Face"
        case .archonRegistry: "Archon Registry"
        case .developerRegistry: "Developer Registry"
        case .directURL: "Direct URL"
        case .localImport: "Local Import"
        }
    }
}

private extension ArchonModelTask {
    var displayName: String {
        switch self {
        case .textGeneration: "Text"
        case .vision: "Vision"
        case .audio: "Audio"
        case .embedding: "Embedding"
        case .imageGeneration: "Image generation"
        case .classification: "Classification"
        case .unknown: "Unknown"
        }
    }
}

/// Managed-library storage screen with real refresh, deletion, and cleanup
/// actions. Temporary cleanup never targets installed model directories.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct ModelStorageView: View {
    private let library: ModelLibrary
    @State private var models: [InstalledModel] = []
    @State private var diskUsage: Int64 = 0
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    public init(library: ModelLibrary = .makeDefault()) {
        self.library = library
    }

    public var body: some View {
        List {
            Section("Storage") {
                LabeledContent("Installed MLX models", value: "\(models.count)")
                LabeledContent("MLX disk usage", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                Button("Clear Temporary Download Data", role: .destructive) {
                    Task { await clearTemporaryStorage() }
                }
            }

            Section("Installed MLX Models") {
                if models.isEmpty {
                    ContentUnavailableView("No Installed MLX Models", systemImage: "shippingbox")
                } else {
                    ForEach(models) { model in
                        HStack(alignment: .center, spacing: 12) {
                            ModelLogoView(
                                logoURL: model.manifest.logoURL,
                                name: model.manifest.modelName,
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.manifest.modelName)
                                Text("\(model.manifest.runtime.rawValue) · \(model.manifest.format.rawValue)\(model.manifest.isExperimental ? " · Experimental" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets) }
                    }
                }
            }
        }
        .navigationTitle("MLX Model Storage")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
            }
        }
        .task {
            await refresh()
        }
        .alert("MLX Model Storage", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown MLX model-storage error.")
        }
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            models = try await library.installedMLXModels()
            diskUsage = try await library.mlxDiskUsageBytes()
            errorMessage = nil
        } catch {
            if !error.isCancellation && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func delete(at offsets: IndexSet) async {
        do {
            for index in offsets {
                guard models.indices.contains(index) else { continue }
                try await library.delete(modelID: models[index].id)
            }
            await refresh()
        } catch {
            if !error.isCancellation && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func clearTemporaryStorage() async {
        do {
            try await library.clearTemporaryStorage()
            await refresh()
        } catch {
            if !error.isCancellation && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Naming aliases that keep headless use independent from this optional UI
/// product while offering the component names used in the architecture docs.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public typealias ModelDiscoveryView = ModelBrowserView

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public typealias ModelDownloadView = ModelBrowserView
