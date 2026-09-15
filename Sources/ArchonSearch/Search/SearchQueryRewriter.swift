import Foundation

/// Deterministic local query variants (SEARCH-002).
///
/// Dependency-free rewriting: normalization plus bounded term-drop variants
/// so parallel discovery fans out without a model or network call.
public struct SearchQueryRewriter: Sendable {
    public init() {}

    public func variants(for query: String, maxVariants: Int = 3) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return [] }
        var out = [normalized]
        let terms = normalized.split(separator: " ").map(String.init)
        if terms.count > 3 {
            out.append(terms.prefix(terms.count - 1).joined(separator: " "))
            out.append(terms.suffix(terms.count - 1).joined(separator: " "))
        } else if terms.count == 3 {
            out.append(terms.prefix(2).joined(separator: " "))
        }
        let lowered = normalized.lowercased()
        if lowered != normalized, !out.contains(lowered) { out.append(lowered) }
        return Array(out.prefix(max(1, maxVariants)))
    }
}
