import Foundation

/// Process and task-scoped network egress guard shared by every Archon
/// product. Keeping this policy in ArchonCore prevents lower-level products
/// such as ArchonMemory from depending on ArchonAgent just to honor
/// ZeroCloudMode.
public enum ArchonNetworkSecurity: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var processZeroCloudEnabled = false

    @TaskLocal
    private static var scopedZeroCloudEnabled: Bool?

    /// Whether remote network egress is currently denied.
    public static var isZeroCloudEnabled: Bool {
        if let scopedZeroCloudEnabled {
            return scopedZeroCloudEnabled
        }

        lock.lock()
        defer { lock.unlock() }
        return processZeroCloudEnabled
    }

    /// Runs an operation with a task-inherited local-only network policy.
    public static func withZeroCloud<Result: Sendable>(
        _ operation: sending () async throws -> Result
    ) async rethrows -> Result {
        try await $scopedZeroCloudEnabled.withValue(true) {
            try await operation()
        }
    }

    /// Updates the process-wide local-only policy used by unscoped work.
    public static func setProcessZeroCloudEnabled(_ enabled: Bool) {
        lock.lock()
        processZeroCloudEnabled = enabled
        lock.unlock()
    }

    /// Fails before a remote provider request is constructed or opened.
    public static func ensureRemoteNetworkAllowed(provider: String) throws {
        guard isZeroCloudEnabled else { return }
        throw ArchonNetworkPolicyError.zeroCloudViolation(provider: provider)
    }

    /// Allows a local model server in ZeroCloudMode only when its endpoint is
    /// an explicit loopback HTTP endpoint. Custom endpoints must not turn a
    /// local-provider compatibility path into arbitrary network egress.
    public static func ensureLoopbackEndpointAllowed(
        _ endpoint: URL,
        provider: String
    ) throws {
        guard isZeroCloudEnabled else { return }
        let host = endpoint.host?.lowercased()
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard endpoint.scheme?.lowercased() == "http",
              let host,
              loopbackHosts.contains(host) else {
            throw ArchonNetworkPolicyError.zeroCloudViolation(provider: provider)
        }
    }
}
