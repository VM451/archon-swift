import Foundation

/// A validated WebAssembly asset living inside the sandbox workspace.
///
/// WASM executes in WebKit (`.inProcessWebKit`) via page JavaScript inside the
/// existing isolation boundary. It is never a VM, container, or separate
/// process; CSP keeps `'wasm-unsafe-eval'` only while
/// `SandboxConfiguration.enableWebAssembly` is true.
public struct SandboxWasmModule: Sendable, Equatable {
    /// Workspace-relative path of the `.wasm` asset (e.g. `"assets/model.wasm"`).
    public var path: String
    /// Caller-requested size ceiling, clamped by the global policy maximum.
    public var maxBytes: Int

    public init(path: String, maxBytes: Int = SandboxWasmPolicy.defaultMaximumModuleBytes) {
        self.path = path
        self.maxBytes = maxBytes
    }
}

public enum SandboxWasmError: Error, LocalizedError, Equatable, Sendable {
    case webAssemblyDisabled
    case invalidPath(String)
    case moduleNotFound(String)
    case moduleTooLarge(path: String, size: Int, maximum: Int)
    case invalidModule(String)

    public var errorDescription: String? {
        switch self {
        case .webAssemblyDisabled:
            return "WebAssembly execution is disabled by the sandbox configuration."
        case .invalidPath(let path):
            return "Invalid WebAssembly module path: \(path)"
        case .moduleNotFound(let path):
            return "WebAssembly module not found in the sandbox workspace: \(path)"
        case .moduleTooLarge(let path, let size, let maximum):
            return "WebAssembly module \(path) is \(size) bytes, exceeding the \(maximum)-byte limit."
        case .invalidModule(let path):
            return "WebAssembly module failed validation (expected a .wasm asset with a valid magic header): \(path)"
        }
    }
}

/// Fail-closed validation for WASM-in-WebKit assets. WebKit-free and
/// deterministic so hosts and tests can validate without a live page.
public enum SandboxWasmPolicy: Sendable {
    /// Default per-module ceiling (4 MiB).
    public static let defaultMaximumModuleBytes = 4 * 1024 * 1024
    /// Absolute ceiling no caller request can exceed (16 MiB).
    public static let absoluteMaximumModuleBytes = 16 * 1024 * 1024
    public static let maximumPathLength = 512

    private static let wasmMagic = Data([0x00, 0x61, 0x73, 0x6D])

    /// Validates the module against the workspace and configuration, returning
    /// the workspace file on success. Throws `SandboxWasmError` otherwise.
    public static func validatedFile(
        for module: SandboxWasmModule,
        in workspace: SandboxWorkspace,
        configuration: SandboxConfiguration
    ) throws -> SandboxFile {
        guard configuration.enableWebAssembly else {
            throw SandboxWasmError.webAssemblyDisabled
        }
        guard let normalized = normalizedPath(module.path) else {
            throw SandboxWasmError.invalidPath(module.path)
        }
        guard (normalized as NSString).pathExtension.lowercased() == "wasm" else {
            throw SandboxWasmError.invalidModule(module.path)
        }
        guard let file = workspace.file(at: normalized) else {
            throw SandboxWasmError.moduleNotFound(module.path)
        }
        let maximum = min(max(module.maxBytes, 1), absoluteMaximumModuleBytes)
        guard file.sizeInBytes <= maximum else {
            throw SandboxWasmError.moduleTooLarge(
                path: module.path,
                size: file.sizeInBytes,
                maximum: maximum
            )
        }
        guard file.content.rawData.prefix(4) == wasmMagic else {
            throw SandboxWasmError.invalidModule(module.path)
        }
        return file
    }

    private static func normalizedPath(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.count <= maximumPathLength else { return nil }
        var relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        relative = relative.removingPercentEncoding ?? relative
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return nil }
            if component.contains("\\") || component.contains("\0") { return nil }
        }
        return components.joined(separator: "/")
    }
}
