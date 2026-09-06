import Foundation
import CoreGraphics
import ArchonCore

/// Configuration parameters governing the sandbox execution perimeter, security policy, and UI rendering.
public struct SandboxConfiguration: Sendable, Equatable {
    /// Determines whether the sandbox can make outbound HTTP/HTTPS network requests. Defaults to `false` for zero-trust local isolation.
    ///
    /// This property is retained for source compatibility. New code should prefer
    /// `allowedPermissions`, which is the single capability policy used by the
    /// WebKit bridge and navigation delegates.
    public var allowNetworkAccess: Bool

    /// Explicit capabilities granted to the sandbox. The default is empty
    /// (network, storage, clipboard, camera, microphone, location, and external
    /// URLs are all denied).
    public var allowedPermissions: Set<ArchonPermission>
    
    /// Enables or disables WebAssembly (.wasm) execution within the JavaScript environment. Defaults to `true`.
    public var enableWebAssembly: Bool
    
    /// Enables or disables WebGPU / WebGL hardware accelerated rendering contexts. Defaults to `true`.
    public var enableWebGPU: Bool
    
    /// Corner radius applied to the native SwiftUI SandboxView container. Defaults to `12.0`.
    public var cornerRadius: CGFloat
    
    /// Maximum allowed memory ceiling in megabytes before the watchdog triggers an alert/purge. Defaults to `256` MB.
    public var maxMemoryMB: Int
    
    /// Custom Content Security Policy (CSP) string to override the default zero-trust policy.
    public var customCSP: String?
    
    /// Enables developer overlay tools, live console stream inspector, and AST inspector. Defaults to `false`.
    public var developerModeEnabled: Bool
    
    /// Whitelist of allowed URL schemes within the sandbox. Defaults to `["sandbox", "data", "blob"]`.
    public var allowedSchemes: [String]
    
    /// Enables Safari Web Inspector debugging (supported on macOS and modern iOS simulators/devices). Defaults to `true`.
    public var isInspectable: Bool
    
    /// Polling interval for memory watchdog checking.
    public var watchdogCheckIntervalSeconds: TimeInterval

    /// Tool names explicitly approved for invocation by page JavaScript.
    /// Every page-originated tool requires an entry in this set; a tool's
    /// read-only classification describes effects but is not authorization.
    public var allowedSandboxToolNames: Set<String>
    
    public init(
        allowNetworkAccess: Bool = false,
        allowedPermissions: Set<ArchonPermission> = [],
        enableWebAssembly: Bool = true,
        enableWebGPU: Bool = true,
        cornerRadius: CGFloat = 12.0,
        maxMemoryMB: Int = 256,
        customCSP: String? = nil,
        developerModeEnabled: Bool = false,
        allowedSchemes: [String] = ["sandbox", "data", "blob"],
        isInspectable: Bool = true,
        watchdogCheckIntervalSeconds: TimeInterval = 5.0,
        allowedSandboxToolNames: Set<String> = []
    ) {
        self.allowNetworkAccess = allowNetworkAccess
        self.allowedPermissions = allowedPermissions
        self.enableWebAssembly = enableWebAssembly
        self.enableWebGPU = enableWebGPU
        self.cornerRadius = cornerRadius
        self.maxMemoryMB = maxMemoryMB
        self.customCSP = customCSP
        self.developerModeEnabled = developerModeEnabled
        self.allowedSchemes = allowedSchemes
        self.isInspectable = isInspectable
        self.watchdogCheckIntervalSeconds = watchdogCheckIntervalSeconds
        self.allowedSandboxToolNames = allowedSandboxToolNames
    }
    
    public static let `default` = SandboxConfiguration()

    /// Returns whether a capability is enabled for this sandbox.
    ///
    /// `allowNetworkAccess` is treated as a compatibility alias for the network
    /// permission so existing clients do not silently lose access when adopting
    /// the capability-based policy.
    public func allows(_ permission: ArchonPermission) -> Bool {
        permission == .network
            ? allowNetworkAccess || allowedPermissions.contains(.network)
            : allowedPermissions.contains(permission)
    }

    /// Returns whether a URL scheme is allowed by both the scheme allowlist and
    /// the capability policy. The legacy network flag preserves the historical
    /// `https`/`wss` defaults for clients that have not adopted permissions.
    public func allowsURLScheme(_ scheme: String) -> Bool {
        let normalizedScheme = scheme.lowercased()
        if allowedSchemes.map({ $0.lowercased() }).contains(normalizedScheme) {
            return true
        }
        return allowedPermissions.isEmpty
            && allowNetworkAccess
            && ["https", "wss"].contains(normalizedScheme)
    }

    /// Normalized URL schemes used when generating the enforced CSP.
    public var effectiveAllowedSchemes: Set<String> {
        var schemes = Set(allowedSchemes.map { $0.lowercased() })
        if allowedPermissions.isEmpty && allowNetworkAccess {
            schemes.formUnion(["https", "wss"])
        }
        return schemes
    }
    
    /// High-security configuration with network fully disabled, strict memory limits, and tight CSP.
    public static let secure = SandboxConfiguration(
        allowNetworkAccess: false,
        enableWebAssembly: true,
        enableWebGPU: false,
        cornerRadius: 12.0,
        maxMemoryMB: 128,
        developerModeEnabled: false,
        isInspectable: false
    )
    
    /// Developer configuration with inspectability and console overlays enabled.
    public static let developer = SandboxConfiguration(
        allowNetworkAccess: false,
        enableWebAssembly: true,
        enableWebGPU: true,
        cornerRadius: 12.0,
        maxMemoryMB: 512,
        developerModeEnabled: true,
        isInspectable: true
    )
}
