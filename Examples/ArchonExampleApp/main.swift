import SwiftUI
import ArchonAgent
import ArchonModels
import ArchonModelsUI

/// A small native host that demonstrates the complete model-library surface.
///
/// The example deliberately keeps credentials, entitlements, and model-runtime
/// adapters in the consuming app. Hugging Face authentication is therefore
/// resolved by `HuggingFaceCatalog` from its Keychain-backed token store, while
/// the shared library and download manager own the actual lifecycle.
@main
struct ArchonExampleApp: App {
    private let library: ModelLibrary
    private let catalog: HuggingFaceCatalog
    private let downloadManager: ModelDownloadManager
    private let systemModelProvider: AppleFoundationModelProvider

    init() {
        let library = ModelLibrary.makeDefault()
        self.library = library
        self.catalog = HuggingFaceCatalog()
        self.downloadManager = ModelDownloadManager()
        self.systemModelProvider = AppleFoundationModelProvider.default

        Task {
            await ModelLibraryIntentRegistry.shared.register(library)
        }
    }

    var body: some Scene {
        WindowGroup("Archon Models") {
            ArchonExampleRootView(
                library: library,
                catalog: catalog,
                downloadManager: downloadManager,
                systemModelProvider: systemModelProvider
            )
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct ArchonExampleRootView: View {
    private enum Destination: String, CaseIterable, Hashable, Identifiable {
        case library
        case discover
        case storage
        case inference

        var id: Self { self }

        var title: String {
            switch self {
            case .library: "Installed"
            case .discover: "Discover"
            case .storage: "Storage"
            case .inference: "System Model"
            }
        }

        var systemImage: String {
            switch self {
            case .library: "shippingbox"
            case .discover: "magnifyingglass"
            case .storage: "internaldrive"
            case .inference: "bubble.left.and.bubble.right"
            }
        }
    }

    private let library: ModelLibrary
    private let catalog: HuggingFaceCatalog
    private let downloadManager: ModelDownloadManager
    private let systemModelProvider: AppleFoundationModelProvider
    @State private var selection: Destination? = .library

    init(
        library: ModelLibrary,
        catalog: HuggingFaceCatalog,
        downloadManager: ModelDownloadManager,
        systemModelProvider: AppleFoundationModelProvider
    ) {
        self.library = library
        self.catalog = catalog
        self.downloadManager = downloadManager
        self.systemModelProvider = systemModelProvider
    }

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Archon")
        } detail: {
            NavigationStack {
                switch selection ?? .library {
                case .library:
                    ModelLibraryView(
                        library: library,
                        catalog: catalog,
                        downloadManager: downloadManager
                    )
                case .discover:
                    ModelBrowserView(
                        catalog: catalog,
                        library: library,
                        downloadManager: downloadManager
                    )
                case .storage:
                    ModelStorageView(library: library)
                case .inference:
                    SystemModelChatView(provider: systemModelProvider)
                }
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct SystemModelChatView: View {
    private let provider: AppleFoundationModelProvider
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    init(provider: AppleFoundationModelProvider) {
        self.provider = provider
    }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                ContentUnavailableView(
                    "Ask the System Model",
                    systemImage: "apple.intelligence",
                    description: Text("Messages are sent to Apple's on-device Foundation Model when it is available.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            HStack {
                                if message.role == .user { Spacer(minLength: 48) }
                                Text(message.content)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(
                                        message.role == .user
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.secondary.opacity(0.12)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                if message.role != .user { Spacer(minLength: 48) }
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message the system model", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)

                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(isGenerating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle("System Model")
        .overlay {
            if isGenerating {
                ProgressView("Generating…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("System Model", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The system model is unavailable.")
        }
    }

    @MainActor
    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        messages.append(.user(prompt))
        draft = ""
        isGenerating = true

        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let response = try await provider.generate(
                    prompt: messages,
                    tools: [],
                    options: GenerationOptions(maxTokens: 512)
                )
                messages.append(.assistant(response.text))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
