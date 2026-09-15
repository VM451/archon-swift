import SwiftUI
import ArchonCore

/// Public disclosure surface for the WebKit isolation boundary.
///
/// Shows the derived isolation level, its plain-language disclosure, and the
/// exact granted permissions. Renders denied-by-default state explicitly so a
/// host cannot mistake an empty permission set for an error.
public struct SandboxIsolationDisclosureView: View {
    private let configuration: SandboxConfiguration

    public init(configuration: SandboxConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: configuration.isolationLevel == .strictLocal ? "lock.shield.fill" : "exclamationmark.shield.fill")
                    .accessibilityHidden(true)
                Text("Isolation: \(configuration.isolationLevel.rawValue)")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .accessibilityLabel("Sandbox isolation \(configuration.isolationLevel.rawValue)")
            Text(configuration.isolationDisclosure)
                .font(.caption2)
                .foregroundColor(.secondary)
            if configuration.allowedPermissions.isEmpty && !configuration.allowNetworkAccess {
                Text("Granted permissions: none (deny by default)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                let names = ArchonPermission.allCases
                    .filter { configuration.allows($0) }
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ", ")
                Text("Granted permissions: \(names)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
    }
}
