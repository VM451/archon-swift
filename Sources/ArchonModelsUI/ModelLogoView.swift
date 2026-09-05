import SwiftUI
import ArchonModels

/// Displays catalog artwork when available and keeps a native provider-aware
/// symbol fallback visible when artwork is missing, blocked, or still loading.
struct ModelLogoView: View {
    private let logoURL: URL?
    private let name: String
    private let size: CGFloat

    init(model: ModelDescriptor, size: CGFloat = 44) {
        self.init(logoURL: model.logoURL, name: model.publisher + " " + model.name, size: size)
    }

    init(logoURL: URL?, name: String, size: CGFloat = 44) {
        self.logoURL = logoURL
        self.name = name
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(fallbackTint.opacity(0.12))

            if let logoURL = validatedLogoURL {
                AsyncImage(url: logoURL, transaction: Transaction(animation: nil)) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.16)
                    } else {
                        fallbackImage
                    }
                }
            } else {
                fallbackImage
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private var fallbackImage: some View {
        Image(systemName: fallbackIcon)
            .font(.system(size: size * 0.45))
            .foregroundStyle(fallbackTint)
    }

    private var validatedLogoURL: URL? {
        guard let logoURL,
              logoURL.scheme?.lowercased() == "https",
              let host = logoURL.host,
              !host.isEmpty,
              logoURL.user == nil,
              logoURL.password == nil else { return nil }
        return logoURL
    }

    private var fallbackIcon: String {
        let value = name.lowercased()
        if value.contains("apple") { return "apple.logo" }
        if value.contains("google") || value.contains("gemma") { return "sparkles" }
        if value.contains("meta") || value.contains("llama") { return "brain.head.profile" }
        if value.contains("qwen") { return "cpu" }
        if value.contains("mistral") { return "wind" }
        return "cpu"
    }

    private var fallbackTint: Color {
        let value = name.lowercased()
        if value.contains("apple") { return .primary }
        if value.contains("google") || value.contains("gemma") { return .blue }
        if value.contains("meta") || value.contains("llama") { return .indigo }
        if value.contains("qwen") { return .purple }
        if value.contains("mistral") { return .orange }
        return .secondary
    }
}
