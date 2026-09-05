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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fallbackTint.opacity(0.12))

            if let targetURL = effectiveLogoURL {
                AsyncImage(url: targetURL, transaction: Transaction(animation: nil)) { phase in
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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallbackImage: some View {
        if let bundledImage = bundledProviderLogo {
            bundledImage
                .resizable()
                .scaledToFit()
                .padding(size * 0.16)
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: size * 0.45))
                .foregroundStyle(fallbackTint)
        }
    }

    private var bundledProviderLogo: Image? {
        let value = name.lowercased()
        if value.contains("qwen") {
            return Image("qwen_logo", bundle: .module)
        }
        if value.contains("meta") || value.contains("llama") {
            return Image("meta_logo", bundle: .module)
        }
        if value.contains("google") || value.contains("gemma") {
            return Image("google_logo", bundle: .module)
        }
        if value.contains("mistral") {
            return Image("mistral_logo", bundle: .module)
        }
        return nil
    }

    private var effectiveLogoURL: URL? {
        if let validated = validatedLogoURL {
            return validated
        }
        return defaultProviderLogoURL
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

    private var defaultProviderLogoURL: URL? {
        let value = name.lowercased()
        if value.contains("qwen") {
            return URL(string: "https://cdn-avatars.huggingface.co/v1/production/uploads/6215ca5692c0ecfba9186921/hrRM50-6XcdWgg2AKpENG.jpeg")
        }
        if value.contains("meta") || value.contains("llama") {
            return URL(string: "https://cdn-avatars.huggingface.co/v1/production/uploads/646cf8084eefb026fb8fd8bc/oCTqufkdTkjyGodsx1vo1.png")
        }
        if value.contains("google") || value.contains("gemma") {
            return URL(string: "https://cdn-avatars.huggingface.co/v1/production/uploads/5dd96eb166059660ed1ee413/WtA3YYitedOr9n02eHfJe.png")
        }
        if value.contains("mistral") {
            return URL(string: "https://cdn-avatars.huggingface.co/v1/production/uploads/634c17653d11eaedd88b314d/9OgyfKstSZtbmsmuG8MbU.png")
        }
        return nil
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
