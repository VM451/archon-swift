import Foundation

/// Thread-safe storage for explicit test and preview responses.
///
/// Providers are Sendable reference types because they can be shared by graph
/// tasks. This lock keeps the opt-in mock hook from introducing a data race;
/// production requests still use the real runtime adapter.
final class MockResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: String]

    init(_ responses: [String: String]) {
        self.responses = responses
    }

    func set(_ response: String, for substring: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[substring] = response
    }

    func response(for prompt: String, caseSensitive: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }

        return responses.first { key, _ in
            caseSensitive
                ? prompt.contains(key)
                : prompt.localizedCaseInsensitiveContains(key)
        }?.value
    }
}
