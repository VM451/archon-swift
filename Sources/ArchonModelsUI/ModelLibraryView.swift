import SwiftUI
import UniformTypeIdentifiers
import ArchonCore
import ArchonModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct ModelLibraryView: View {
    private let library: ModelLibrary
    private let catalog: (any ModelCatalogProvider)?
    private let downloadManager: ModelDownloadManager
    private let deviceOverride: ArchonDeviceCapabilities?
    @State private var models: [InstalledModel] = []
    @State private var updates: [String: ModelUpdateCandidate] = [:]
    @State private var updateStatus: [String: String] = [:]
    @State private var updatingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var isRefreshing = false
    @State private var isCheckingUpdates = false
    @State private var isImporting = false

    public init(
        library: ModelLibrary = .makeDefault(),
        catalog: (any ModelCatalogProvider)? = nil,
        downloadManager: ModelDownloadManager = ModelDownloadManager(),
        device: ArchonDeviceCapabilities? = nil
    ) {
        self.library = library
        self.catalog = catalog
        self.downloadManager = downloadManager
        self.deviceOverride = device
    }

    public var body: some View {
        Group {
            if models.isEmpty, !isRefreshing {
                ContentUnavailableView("No Installed Models", systemImage: "shippingbox", description: Text("Download or import a runnable model to see it here."))
            } else {
                List {
                    ForEach(models) { model in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading) {
                                    Text(model.manifest.modelName)
                                        .font(.headline)
                                    Text(model.manifest.runtime.rawValue + " · " + model.manifest.format.rawValue + (model.manifest.isExperimental ? " · Experimental" : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let candidate = updates[model.id] {
                                    Button(
                                        updatingIDs.contains(model.id) ? "Updating…" : "Update",
                                        systemImage: "arrow.down.circle"
                                    ) {
                                        update(candidate)
                                    }
                                    .disabled(updatingIDs.contains(model.id) || candidate.variant == nil)
                                }
                            }
                            if updates[model.id] != nil {
                                Label(
                                    updateStatus[model.id] ?? "Update available",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { models[safe: $0]?.id }
                        Task {
                            do {
                                for id in ids { try await library.delete(modelID: id) }
                                await refresh()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Model Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import Model", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .disabled(isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
            }
            if let catalog {
                ToolbarItem {
                    Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await checkForUpdates(using: catalog) }
                    }
                    .disabled(isCheckingUpdates || isRefreshing)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    await importArtifacts(urls)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { @MainActor in
                await importArtifacts(urls)
            }
            return true
        }
        .task {
            await refresh()
        }
        .alert("Model Library", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown model-library error.")
        }
    }

    private var device: ArchonDeviceCapabilities {
        // A supplied device keeps previews/tests deterministic. Production
        // views refresh the advisory headroom each time an operation is run.
        deviceOverride ?? .current
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            models = try await library.installedModels()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importArtifacts(_ urls: [URL]) async {
        isRefreshing = true
        defer { isRefreshing = false }

        var importedCount = 0
        var failures: [String] = []
        for url in urls {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                _ = try await library.importArtifact(at: url)
                importedCount += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        await refresh()
        guard !failures.isEmpty else { return }
        let summary = failures.joined(separator: "\n")
        errorMessage = importedCount == 0
            ? summary
            : "Imported \(importedCount) model(s).\n\(summary)"
    }

    @MainActor
    private func checkForUpdates(using catalog: any ModelCatalogProvider) async {
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        do {
            let candidates = try await library.checkForUpdates(using: catalog)
            updates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.installedModelID, $0) })
            updateStatus = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.installedModelID, "Update available: \($0.currentRevision) → \($0.availableRevision)")
            })
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func update(_ candidate: ModelUpdateCandidate) {
        let modelID = candidate.installedModelID
        updatingIDs.insert(modelID)
        updateStatus[modelID] = "Queued"
        Task { @MainActor in
            defer { updatingIDs.remove(modelID) }
            do {
                let stream = try await downloadManager.update(candidate, into: library, on: device)
                for try await event in stream {
                    switch event.state {
                    case .queued:
                        updateStatus[modelID] = "Queued"
                    case .resolving:
                        updateStatus[modelID] = "Resolving"
                    case .downloading(let progress, _, _):
                        updateStatus[modelID] = "Downloading \(Int(progress * 100))%"
                    case .paused:
                        updateStatus[modelID] = "Paused"
                    case .verifying:
                        updateStatus[modelID] = "Verifying"
                    case .installing:
                        updateStatus[modelID] = "Installing"
                    case .ready:
                        updates.removeValue(forKey: modelID)
                        updateStatus.removeValue(forKey: modelID)
                        await refresh()
                    case .updateAvailable:
                        updateStatus[modelID] = "Update available"
                    case .failed(let message):
                        updateStatus[modelID] = message
                    case .cancelled:
                        updateStatus[modelID] = "Cancelled"
                    }
                }
            } catch {
                updateStatus[modelID] = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A small, functional catalog browser. The caller supplies the catalog and
/// manager so network/auth/runtime policy remains in the host application.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct ModelBrowserView: View {
    private enum Collection: String, CaseIterable, Identifiable {
        case all
        case recommended
        case downloaded
        case appleCoreAI
        case huggingFace

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All Models"
            case .recommended: "Recommended"
            case .downloaded: "Downloaded"
            case .appleCoreAI: "Apple / Core AI Ready"
            case .huggingFace: "Hugging Face"
            }
        }
    }

    private let title: String
    private let catalog: any ModelCatalogProvider
    private let library: ModelLibrary
    private let downloadManager: ModelDownloadManager
    private let deviceOverride: ArchonDeviceCapabilities?
    private let pageSize = 20
    @State private var query = ""
    @State private var results: [ModelDescriptor] = []
    @State private var nextOffset = 0
    @State private var nextContinuationToken: String?
    @State private var hasMoreResults = false
    @State private var isInitialLoading = false
    @State private var isLoadingMore = false
    @State private var installedModels: [InstalledModel] = []
    @State private var progress: [String: Double] = [:]
    @State private var status: [String: String] = [:]
    @State private var phase: [String: DownloadPhase] = [:]
    @State private var compatibleOnly = false
    @State private var collection: Collection = .all
    @State private var selectedTaskRaw = ""
    @State private var selectedRuntimeRaw = ""
    @State private var publisherFilter = ""
    @State private var licenseFilter = ""
    @State private var maximumSizeGB = 0
    @State private var searchError: String?

    public init(
        title: String = "Models Discovery",
        catalog: any ModelCatalogProvider,
        library: ModelLibrary = .makeDefault(),
        downloadManager: ModelDownloadManager = ModelDownloadManager(),
        device: ArchonDeviceCapabilities? = nil
    ) {
        self.title = title
        self.catalog = catalog
        self.library = library
        self.downloadManager = downloadManager
        self.deviceOverride = device
    }

    public var body: some View {
        List {
            if isInitialLoading, results.isEmpty {
                Section {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if !isInitialLoading, displayedResults.isEmpty, !hasMoreResults {
                Section {
                    ContentUnavailableView(
                        "No Models Found",
                        systemImage: "shippingbox",
                        description: Text("Try changing the search or filters.")
                    )
                }
            }

            ForEach(displayedResults) { model in
                Section(model.name) {
                    ForEach(model.variants) { variant in
                        let compatibility = ModelCompatibilityAnalyzer.analyze(
                            variant: variant,
                            device: device,
                            isInstalled: isInstalled(variant)
                        )
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.publisher)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(variant.name)
                                Text("\(variant.runtime.rawValue) · \(compatibility.status.displayName) · \(compatibility.fit.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let message = status[variant.id] {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let value = progress[variant.id] {
                                    ProgressView(value: value)
                                }
                            }
                            Spacer()
                            switch phase[variant.id] {
                            case .downloading:
                                Button("Pause") { pause(variantID: variant.id) }
                                Button("Cancel", role: .cancel) { cancel(variantID: variant.id) }
                            case .paused:
                                Button("Resume") { resume(variant, descriptor: model) }
                                Button("Cancel", role: .cancel) { cancel(variantID: variant.id) }
                            case .failed, .cancelled:
                                Button("Retry") { retry(variant, descriptor: model) }
                            case .ready:
                                Button("Redownload") { redownload(variant, descriptor: model) }
                            default:
                                if isInstalled(variant) {
                                    Button("Redownload") { redownload(variant, descriptor: model) }
                                } else {
                                    Button(compatibility.canLoad ? "Download" : compatibility.status == .conversionRequired ? "Conversion required" : "Unavailable") {
                                        beginDownload(variant, descriptor: model)
                                    }
                                    .disabled(
                                        !compatibility.canLoad ||
                                        (variant.downloadURL == nil && variant.resources.isEmpty && variant.tokenizerResources.isEmpty)
                                    )
                                }
                            }
                            NavigationLink("Details") {
                                ModelDetailView(
                                    model: model,
                                    device: deviceOverride,
                                    library: library,
                                    downloadManager: downloadManager
                                )
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            if hasMoreResults {
                Section {
                    if isLoadingMore {
                        ProgressView("Loading more models…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if displayedResults.isEmpty {
                        Button("Load more models", systemImage: "arrow.down.circle") {
                            requestNextPage()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("Scroll to load more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .id("model-discovery-page-\(nextOffset)-\(nextContinuationToken ?? "initial")")
                .task {
                    // List keeps this footer lazy, so this task starts when
                    // the user reaches the current page boundary. Empty
                    // filtered pages keep an explicit button so a restrictive
                    // filter cannot trigger an unbounded network scan.
                    guard !displayedResults.isEmpty else { return }
                    await loadNextPage()
                }
            }
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle(title)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
            #endif
        }
        .task(id: "\(query)|\(compatibleOnly)|\(selectedTaskRaw)|\(selectedRuntimeRaw)") {
            do {
                // Search fields can change several times while the user is
                // typing. Debounce them so each keystroke does not start a
                // separate catalog request.
                try await Task.sleep(for: .milliseconds(250))
                await search()
            } catch is CancellationError {
                // SwiftUI cancels this task when the search identity changes.
            } catch {
                searchError = error.localizedDescription
            }
        }
        .task {
            await refreshInstalledModels()
        }
        .alert("Model Discovery", isPresented: Binding(
            get: { searchError != nil },
            set: { if !$0 { searchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(searchError ?? "The model catalog could not be queried.")
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Runs on This Device", isOn: $compatibleOnly)

            Divider()

            Picker("Collection", selection: $collection) {
                ForEach(Collection.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Picker("Task", selection: $selectedTaskRaw) {
                Text("All Tasks").tag("")
                ForEach(ArchonModelTask.allCases, id: \.rawValue) { task in
                    Text(task.displayName).tag(task.rawValue)
                }
            }

            Picker("Runtime", selection: $selectedRuntimeRaw) {
                Text("All Runtimes").tag("")
                ForEach(ArchonModelRuntime.allCases, id: \.rawValue) { runtime in
                    Text(runtime.displayName).tag(runtime.rawValue)
                }
            }

            Picker("Maximum Model Size", selection: $maximumSizeGB) {
                Text("Any size").tag(0)
                Text("Up to 2 GB").tag(2)
                Text("Up to 4 GB").tag(4)
                Text("Up to 8 GB").tag(8)
                Text("Up to 16 GB").tag(16)
            }

            if hasActiveFilters {
                Divider()
                Button(role: .destructive) {
                    resetFilters()
                } label: {
                    Label("Reset Filters", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter models")
    }

    private var hasActiveFilters: Bool {
        compatibleOnly || collection != .all || !selectedTaskRaw.isEmpty || !selectedRuntimeRaw.isEmpty || maximumSizeGB > 0 || !publisherFilter.isEmpty || !licenseFilter.isEmpty
    }

    private func resetFilters() {
        compatibleOnly = false
        collection = .all
        selectedTaskRaw = ""
        selectedRuntimeRaw = ""
        maximumSizeGB = 0
        publisherFilter = ""
        licenseFilter = ""
    }

    private var device: ArchonDeviceCapabilities {
        deviceOverride ?? .current
    }

    private var displayedResults: [ModelDescriptor] {
        results.compactMap { model in
            let variants = model.variants.filter { variant in
                if let task = selectedTask, !variant.capabilities.tasks.contains(task) { return false }
                if let runtime = selectedRuntime, variant.runtime != runtime { return false }
                if !publisherFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !model.publisher.localizedCaseInsensitiveContains(publisherFilter) { return false }
                if !licenseFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !(model.license?.identifier ?? "").localizedCaseInsensitiveContains(licenseFilter) { return false }
                if maximumSizeGB > 0 {
                    guard let size = variant.sizeBytes,
                          size <= Int64(maximumSizeGB) * 1_000_000_000 else { return false }
                }
                if collection == .downloaded && !isInstalled(variant) { return false }
                if collection == .appleCoreAI && variant.runtime != .coreAI && variant.runtime != .foundationModels { return false }
                if collection == .huggingFace && model.source != .huggingFace { return false }
                if collection == .recommended {
                    let fit = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device).fit
                    guard fit == .excellentFit || fit == .goodFit else { return false }
                }
                return true
            }
            guard !variants.isEmpty else { return nil }
            return ModelDescriptor(
                id: model.id,
                name: model.name,
                publisher: model.publisher,
                family: model.family,
                parameterCount: model.parameterCount,
                tasks: model.tasks,
                architecture: model.architecture,
                description: model.description,
                source: model.source,
                sourceURL: model.sourceURL,
                revision: model.revision,
                license: model.license,
                gated: model.gated,
                supportedLanguages: model.supportedLanguages,
                variants: variants
            )
        }
    }

    private var selectedTask: ArchonModelTask? {
        selectedTaskRaw.isEmpty ? nil : ArchonModelTask(rawValue: selectedTaskRaw)
    }

    private var selectedRuntime: ArchonModelRuntime? {
        selectedRuntimeRaw.isEmpty ? nil : ArchonModelRuntime(rawValue: selectedRuntimeRaw)
    }

    private func isInstalled(_ variant: ModelVariant) -> Bool {
        installedModels.contains {
            $0.manifest.modelID == variant.modelID &&
            $0.manifest.runtime == variant.runtime &&
            $0.manifest.format == variant.format
        }
    }

    @MainActor
    private func refreshInstalledModels() async {
        installedModels = (try? await library.installedModels()) ?? []
    }

    @MainActor
    private func search() async {
        results = []
        nextOffset = 0
        nextContinuationToken = nil
        hasMoreResults = false
        searchError = nil
        isInitialLoading = true
        defer { isInitialLoading = false }
        await loadNextPage()
    }

    @MainActor
    private func requestNextPage() {
        guard !isInitialLoading, !isLoadingMore, hasMoreResults else { return }
        Task { @MainActor in
            await loadNextPage()
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoadingMore else { return }
        let isFirstPage = results.isEmpty && nextOffset == 0 && nextContinuationToken == nil
        guard isFirstPage || !isInitialLoading else { return }
        isLoadingMore = !isFirstPage
        if isFirstPage { isInitialLoading = true }
        defer {
            isLoadingMore = false
            if isFirstPage { isInitialLoading = false }
        }

        do {
            let request = ModelSearchRequest(
                query: query,
                task: selectedTask,
                runtime: selectedRuntime,
                compatibleOnly: compatibleOnly,
                device: compatibleOnly ? device : nil,
                offset: nextOffset,
                continuationToken: nextContinuationToken,
                limit: pageSize
            )
            let page: ModelCatalogPage
            if let paginatedCatalog = catalog as? any PaginatedModelCatalogProvider {
                page = try await paginatedCatalog.searchPage(request)
            } else {
                let models = try await catalog.search(request)
                let boundedModels = Array(models.prefix(pageSize))
                page = ModelCatalogPage(
                    models: boundedModels,
                    hasMore: models.count >= pageSize
                )
            }
            try Task.checkCancellation()

            let knownIDs = Set(results.map(\.id))
            let newModels = page.models.filter { !knownIDs.contains($0.id) }
            results.append(contentsOf: newModels)
            nextOffset += page.models.count
            nextContinuationToken = page.nextContinuationToken
            hasMoreResults = page.hasMore && (!page.models.isEmpty || page.nextContinuationToken != nil)
            // A custom provider that ignores pagination must not cause an
            // infinite loop when its repeated page contains no new models.
            if !page.models.isEmpty, newModels.isEmpty {
                hasMoreResults = false
            }
        } catch {
            if !(error is CancellationError) {
                if isFirstPage { results = [] }
                hasMoreResults = false
                searchError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func beginDownload(_ variant: ModelVariant, descriptor: ModelDescriptor) {
        status[variant.id] = "Queued"
        phase[variant.id] = .queued
        consume(
            downloadTask: {
                try await downloadManager.download(
                    ModelDownloadRequest(
                        variant: variant,
                        modelName: descriptor.name,
                        license: descriptor.license,
                        sourceRepository: descriptor.id,
                        sourceRevision: descriptor.revision
                    ),
                    into: library,
                    on: device
                )
            },
            variantID: variant.id
        )
    }

    @MainActor
    private func pause(variantID: String) {
        Task {
            await downloadManager.pause(variantID: variantID)
            phase[variantID] = .paused
            status[variantID] = "Paused"
        }
    }

    @MainActor
    private func cancel(variantID: String) {
        Task {
            await downloadManager.cancel(variantID: variantID)
            phase[variantID] = .cancelled
            status[variantID] = "Cancelled"
        }
    }

    @MainActor
    private func resume(_ variant: ModelVariant, descriptor: ModelDescriptor) {
        phase[variant.id] = .queued
        consume(
            downloadTask: { try await downloadManager.resume(variantID: variant.id, into: library, on: device) },
            variantID: variant.id
        )
    }

    @MainActor
    private func retry(_ variant: ModelVariant, descriptor: ModelDescriptor) {
        phase[variant.id] = .queued
        consume(
            downloadTask: { try await downloadManager.retry(variantID: variant.id, into: library, backoff: 0.5, on: device) },
            variantID: variant.id
        )
    }

    @MainActor
    private func redownload(_ variant: ModelVariant, descriptor: ModelDescriptor) {
        phase[variant.id] = .queued
        consume(
            downloadTask: { try await downloadManager.redownload(variantID: variant.id, into: library, on: device) },
            variantID: variant.id
        )
    }

    @MainActor
    private func consume(
        downloadTask: @escaping @Sendable () async throws -> AsyncThrowingStream<ModelDownloadEvent, Error>,
        variantID: String
    ) {
        Task { @MainActor in
            do {
                let stream = try await downloadTask()
                for try await event in stream {
                    switch event.state {
                    case .downloading(let value, _, _):
                        progress[variantID] = value
                        phase[variantID] = .downloading
                        status[variantID] = "Downloading"
                    case .queued:
                        phase[variantID] = .queued
                        status[variantID] = "Queued"
                    case .resolving:
                        phase[variantID] = .resolving
                        status[variantID] = "Resolving"
                    case .paused:
                        phase[variantID] = .paused
                        status[variantID] = "Paused"
                    case .verifying:
                        phase[variantID] = .verifying
                        status[variantID] = "Verifying"
                    case .installing:
                        phase[variantID] = .installing
                        status[variantID] = "Installing"
                    case .ready:
                        progress[variantID] = 1
                        phase[variantID] = .ready
                        status[variantID] = "Ready"
                        await refreshInstalledModels()
                    case .updateAvailable:
                        phase[variantID] = .updateAvailable
                        status[variantID] = "Update Available"
                    case .failed(let message):
                        phase[variantID] = .failed
                        status[variantID] = message
                    case .cancelled:
                        phase[variantID] = .cancelled
                        status[variantID] = "Cancelled"
                    }
                }
            } catch {
                if let modelError = error as? ArchonModelsError, modelError == .cancelled {
                    phase[variantID] = .cancelled
                    status[variantID] = "Cancelled"
                } else if !(error is CancellationError) {
                    phase[variantID] = .failed
                    status[variantID] = error.localizedDescription
                }
            }
        }
    }
}

private enum DownloadPhase {
    case queued, resolving, downloading, paused, verifying, installing
    case ready, updateAvailable, failed, cancelled
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

private extension ArchonModelRuntime {
    var displayName: String {
        switch self {
        case .coreAI: "Core AI"
        case .foundationModels: "Foundation Models"
        case .mlx: "MLX"
        case .remote: "Remote"
        case .unknown: "Unknown"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
