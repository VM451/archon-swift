import Foundation
import ArchonCore

/// WebKit isolation boundary disclosed to hosts and SwiftUI surfaces.
///
/// The sandbox always renders untrusted content in a separate WebKit process.
/// The level describes how much of the surrounding device capability the page
/// is allowed to reach. Fail-closed rule: unknown or widened capability sets
/// report the most restrictive level that still covers them.
public enum SandboxIsolationLevel: String, Codable, CaseIterable, Sendable {
    case strictLocal
    case networkRestricted
    case developer

    /// User-facing disclosure shown on SwiftUI surfaces.
    public var disclosure: String {
        switch self {
        case .strictLocal:
            return "Strict local isolation. Page content runs in a separate WebKit process with no network, storage, clipboard, camera, microphone, location, or external-URL access."
        case .networkRestricted:
            return "Network-restricted isolation. Page content runs in a separate WebKit process. Only the host-approved network schemes and permissions apply."
        case .developer:
            return "Developer isolation. Page content still runs in a separate WebKit process, but the Web Inspector and developer overlay are enabled. Do not use with untrusted content."
        }
    }

    /// Whether remote content may be loaded under this level.
    public var allowsRemoteContent: Bool {
        switch self {
        case .strictLocal: false
        case .networkRestricted: true
        case .developer: false
        }
    }

    /// Whether the level requires explicit host acknowledgement before use.
    public var requiresHostAcknowledgement: Bool {
        self == .developer
    }

    /// Derives the most restrictive level covering a configuration. Fail closed:
    /// any granted permission widens the level instead of being ignored. The
    /// developer overlay widens to developer; bare Web Inspector inspectability
    /// (the default) does not, since it exposes no page capabilities.
    public static func level(
        for permissions: Set<ArchonPermission>,
        allowNetworkAccess: Bool,
        developerModeEnabled: Bool,
        isInspectable: Bool
    ) -> SandboxIsolationLevel {
        _ = isInspectable
        if developerModeEnabled {
            return .developer
        }
        if permissions.isEmpty && !allowNetworkAccess {
            return .strictLocal
        }
        return .networkRestricted
    }
}

/// Fail-closed gate for `sandbox://` URL handling, kept free of WebKit so it
/// stays deterministic and testable on every platform.
public enum SandboxRequestGate: Sendable {
    public static let allowedHost = "app"

    /// Returns a normalized workspace-relative path, or nil when the request
    /// must be denied (unknown host, traversal, absolute path, empty after
    /// normalization, or overlong input).
    public static func workspacePath(
        scheme: String?,
        host: String?,
        path: String,
        entryPointPath: String,
        maximumPathLength: Int = 512
    ) -> String? {
        guard scheme?.lowercased() == "sandbox" else { return nil }
        if let host, !host.isEmpty, host.lowercased() != allowedHost {
            return nil
        }
        guard path.utf8.count <= maximumPathLength else { return nil }
        var relative = path
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        if relative.isEmpty { relative = entryPointPath }
        guard !relative.isEmpty, relative.utf8.count <= maximumPathLength else { return nil }
        guard !relative.hasPrefix("/") else { return nil }
        let decoded = relative.removingPercentEncoding ?? relative
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return nil }
            if component.contains("\\") || component.contains("\0") { return nil }
        }
        let normalized = components.joined(separator: "/")
        guard !normalized.isEmpty else { return nil }
        return normalized
    }
}
