import Foundation
import CoreGraphics

/// Configuration parameters governing the sandbox execution perimeter, security policy, and UI rendering.
public struct SandboxConfiguration: Sendable, Equatable {
    /// Determines whether the sandbox can make outbound HTTP/HTTPS network requests. Defaults to `false` for zero-trust local isolation.
    public var allowNetworkAccess: Bool
    
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
    
    public init(
        allowNetworkAccess: Bool = false,
        enableWebAssembly: Bool = true,
        enableWebGPU: Bool = true,
        cornerRadius: CGFloat = 12.0,
        maxMemoryMB: Int = 256,
        customCSP: String? = nil,
        developerModeEnabled: Bool = false,
        allowedSchemes: [String] = ["sandbox", "data", "blob"],
        isInspectable: Bool = true,
        watchdogCheckIntervalSeconds: TimeInterval = 5.0
    ) {
        self.allowNetworkAccess = allowNetworkAccess
        self.enableWebAssembly = enableWebAssembly
        self.enableWebGPU = enableWebGPU
        self.cornerRadius = cornerRadius
        self.maxMemoryMB = maxMemoryMB
        self.customCSP = customCSP
        self.developerModeEnabled = developerModeEnabled
        self.allowedSchemes = allowedSchemes
        self.isInspectable = isInspectable
        self.watchdogCheckIntervalSeconds = watchdogCheckIntervalSeconds
    }
    
    public static let `default` = SandboxConfiguration()
    
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
