import SwiftUI

/// Compact citation badge rendering e.g. `[1]`, expanding on tap to display source verification details.
public struct CitationBadgeView: View {
    public let citation: Citation
    @State private var isDetailPresented = false

    public init(citation: Citation) {
        self.citation = citation
    }

    public var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            Text(citation.label)
                .font(.caption2.bold())
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isDetailPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Text(citation.title ?? "Source")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if let snippet = citation.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                Link(destination: citation.url) {
                    HStack(spacing: 4) {
                        Text(citation.url.host() ?? citation.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}
