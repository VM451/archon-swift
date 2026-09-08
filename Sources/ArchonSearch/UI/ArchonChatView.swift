import SwiftUI

/// Main conversational search view adhering to Liquid Glass HIG.
public struct ArchonChatView: View {
    @State public var viewModel: ArchonChatViewModel

    public init(client: ArchonSearchClient) {
        self._viewModel = State(initialValue: ArchonChatViewModel(client: client))
    }

    public init(viewModel: ArchonChatViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messagesScrollView

                SearchComposerView(
                    text: $viewModel.inputText,
                    mode: $viewModel.mode,
                    isSearching: viewModel.isSearching
                ) {
                    Task {
                        await viewModel.sendQuery()
                    }
                }
            }
            .navigationTitle("ArchonSearch")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .background(Self.platformBackgroundColor)
        }
    }

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ArchonChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                if !message.citations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.citations) { citation in
                                CitationBadgeView(citation: citation)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
    private static var platformBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.clear
        #endif
    }
}
