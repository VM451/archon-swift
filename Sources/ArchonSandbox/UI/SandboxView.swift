import SwiftUI

/// iOS/macOS SwiftUI view that renders the embedded Web Sandbox and wires it to platform features.
public struct ArchonSandboxView: View {
    @StateObject private var controller: SandboxViewController
    private let configuration: SandboxConfiguration
    
    public init(workspace: SandboxWorkspace, configuration: SandboxConfiguration = .default) {
        self.configuration = configuration
        _controller = StateObject(wrappedValue: SandboxViewController(workspace: workspace, configuration: configuration))
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            #if (os(iOS) || os(macOS)) && canImport(WebKit)
            NativeSandboxRepresentable(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
            #else
            VStack {
                Text("WebKit rendering is not available on this platform.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            #endif
            
            if controller.isLoading {
                ZStack {
                    Color.clear
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                }
            }
            
            if configuration.developerModeEnabled {
                SandboxDeveloperOverlay(controller: controller)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            if let error = controller.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(12)
                .transition(.opacity)
            }
        }
        .task {
            await controller.bootstrap()
        }
    }
}

/// Convenience typealias for `ArchonSandboxView`.
public typealias SandboxView = ArchonSandboxView
