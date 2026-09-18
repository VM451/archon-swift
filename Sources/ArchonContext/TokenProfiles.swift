import Foundation

/// Model families with distinct token-estimation profiles.
public enum ModelFamilyTokenProfile: String, Sendable, CaseIterable {
    case appleFoundation
    case gemma
    case llama
    case mistral
    case claude
    case gpt
    case utf8Fallback
}

/// Deterministic per-family token estimator. Each family maps to an average
/// UTF-8-bytes-per-token divisor; hosts may override with an explicit
/// `charsPerToken` value. Estimates are clamped at zero.
public struct FamilyAwareTokenEstimator: ContextTokenEstimator, Sendable {
    public let family: ModelFamilyTokenProfile
    public let charsPerToken: Int

    public init(family: ModelFamilyTokenProfile, charsPerToken: Int? = nil) {
        self.family = family
        if let charsPerToken {
            self.charsPerToken = max(1, charsPerToken)
        } else {
            self.charsPerToken = Self.divisor(for: family)
        }
    }

    public func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(0, (text.utf8.count + charsPerToken - 1) / charsPerToken)
    }

    /// Average UTF-8 bytes per token for each family. The fallback divisor
    /// matches `UTF8ContextTokenEstimator` exactly.
    public static func divisor(for family: ModelFamilyTokenProfile) -> Int {
        switch family {
        case .appleFoundation:
            4
        case .gemma:
            3
        case .llama:
            4
        case .mistral:
            4
        case .claude:
            3
        case .gpt:
            4
        case .utf8Fallback:
            4
        }
    }
}
