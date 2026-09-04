import Foundation
import Security

/// Guardrail enforcing 100% on-device local execution.
public struct ZeroCloudMode: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _isEnabled: Bool = false

    /// Global toggle forcing all agent executions to run locally on-device.
    public static var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isEnabled = newValue
        }
    }

    /// Verifies that cloud egress is allowed. Throws `GraphError.zeroCloudViolation` if active.
    public static func ensureAllowed(provider: String) throws {
        if isEnabled {
            throw GraphError.zeroCloudViolation("Blocked network egress to external provider '\(provider)'. ZeroCloudMode is active.")
        }
    }

    /// Local model servers remain available in ZeroCloudMode, but a custom endpoint
    /// must still be loopback-only so the mode cannot be bypassed by configuration.
    public static func ensureOllamaEndpointAllowed(_ endpoint: URL) throws {
        guard isEnabled else { return }
        let host = endpoint.host?.lowercased()
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard endpoint.scheme?.lowercased() == "http", let host, localHosts.contains(host) else {
            throw GraphError.zeroCloudViolation(
                "Blocked Ollama endpoint '\(endpoint.absoluteString)'. ZeroCloudMode only permits loopback model servers."
            )
        }
    }
}

/// Secure Apple Keychain wrapper for external API keys and secrets.
public struct KeychainStorage: Sendable {
    private let service: String

    public init(service: String = "com.archon.agent.keys") {
        self.service = service
    }

    public func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GraphError.stateDeserializationFailed("Keychain write error: \(status)")
        }
    }

    public func get(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Sanitizes Personally Identifiable Information (PII) before sending prompts.
public struct PIISanitizer: Sendable {
    private static let emailRegex = try? NSRegularExpression(pattern: "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}", options: [])
    private static let phoneRegex = try? NSRegularExpression(pattern: "\\b\\d{3}[-.]?\\d{3}[-.]?\\d{4}\\b", options: [])
    private static let ssnRegex = try? NSRegularExpression(pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b", options: [])

    public init() {}

    public static func sanitize(text: String) -> String {
        var output = text

        if let regex = emailRegex {
            let range = NSRange(location: 0, length: output.utf16.count)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "[REDACTED_EMAIL]")
        }

        if let regex = phoneRegex {
            let range = NSRange(location: 0, length: output.utf16.count)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "[REDACTED_PHONE]")
        }

        if let regex = ssnRegex {
            let range = NSRange(location: 0, length: output.utf16.count)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "[REDACTED_SSN]")
        }

        return output
    }

    public static func sanitize(prompt: [ChatMessage]) -> [ChatMessage] {
        prompt.map { message in
            ChatMessage(
                id: message.id,
                role: message.role,
                content: sanitize(text: message.content),
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId,
                timestamp: message.timestamp
            )
        }
    }
}
