import SwiftUI

/// Search mode selected in the composer bar.
public enum SearchComposerMode: String, CaseIterable, Identifiable, Sendable {
    case standard = "Search"
    case deepResearch = "Deep Research"

    public var id: String { rawValue }
}

/// Liquid Glass input bar for composing search queries and selecting search modes.
public struct SearchComposerView: View {
    @Binding public var text: String
    @Binding public var mode: SearchComposerMode
    public var isSearching: Bool
    public var onSend: () -> Void

    public init(
        text: Binding<String>,
        mode: Binding<SearchComposerMode>,
        isSearching: Bool = false,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self._mode = mode
        self.isSearching = isSearching
        self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(SearchComposerMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                TextField("Ask anything or enter a search query...", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: onSend) {
                    Group {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.tint)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
