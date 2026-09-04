import SwiftUI

/// Real-time developer overlay providing live console logs, DOM AST inspection, and tool calling monitors.
public struct SandboxDeveloperOverlay: View {
    @ObservedObject public var controller: SandboxViewController
    @State private var selectedTab: Tab = .console
    @State private var searchText: String = ""
    @State private var selectedLogLevel: SandboxEvent.LogLevel?
    
    public enum Tab: String, CaseIterable, Identifiable {
        case console = "Console"
        case dom = "DOM Tree"
        case files = "Files"
        
        public var id: String { rawValue }
    }
    
    public init(controller: SandboxViewController) {
        self.controller = controller
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                
                Spacer()
                
                Button(action: {
                    controller.clearLogs()
                }) {
                    Image(systemName: "trash")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            
            Divider()
            
            // Content Area
            Group {
                switch selectedTab {
                case .console:
                    consoleListView
                case .dom:
                    domTreeView
                case .files:
                    filesListView
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 280)
        .background(Material.ultraThin)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var consoleListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if controller.logs.isEmpty {
                    Text("No console logs or events yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(eventIcon(for: event))
                                .font(.caption2)
                            Text(event.summary)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(eventColor(for: event))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
    
    private var domTreeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace Entry Point: \(controller.workspace.entryPointPath)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("Virtual Files: \(controller.workspace.files.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("Total Size: \(controller.workspace.totalSizeInBytes) bytes")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var filesListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(controller.workspace.files) { file in
                    HStack {
                        Image(systemName: fileIcon(for: file.path))
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Text(file.path)
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(file.sizeInBytes) B")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    Divider().opacity(0.3)
                }
            }
            .padding(.vertical, 6)
        }
    }
    
    private func eventIcon(for event: SandboxEvent) -> String {
        switch event {
        case .consoleLog(let level, _, _):
            switch level {
            case .debug: return "ladybug"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        case .uncaughtError:
            return "xmark.octagon.fill"
        case .domMutation:
            return "arrow.triangle.2.circlepath"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .customMessage:
            return "bubble.left"
        case .lifecycle:
            return "circle.dotted"
        }
    }
    
    private func eventColor(for event: SandboxEvent) -> Color {
        switch event {
        case .consoleLog(let level, _, _):
            switch level {
            case .debug: return .secondary
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        case .uncaughtError:
            return .red
        case .domMutation:
            return .blue
        case .toolCall:
            return .purple
        case .customMessage:
            return .green
        case .lifecycle:
            return .secondary
        }
    }
    
    private func fileIcon(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "js", "mjs": return "applescript"
        case "css": return "paintpalette"
        case "wasm": return "cpu"
        case "json": return "curlybraces"
        default: return "doc.text"
        }
    }
}
