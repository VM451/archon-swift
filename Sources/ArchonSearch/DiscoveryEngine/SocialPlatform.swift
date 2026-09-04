import Foundation

/// A supported public-web social or community platform.
///
/// ArchonSearch uses these values to scope public, indexed discovery queries.
/// They do not provide authenticated API access or bypass a platform's access
/// controls. Some platforms may still require a user login to open a result.
public enum SocialPlatform: String, CaseIterable, Codable, Hashable, Sendable {
    case twitter
    case reddit
    case youtube
    case github
    case bilibili
    case facebook
    case instagram
    case linkedin
    case xiaohongshu
    case v2ex

    /// The human-readable platform name shown in agent results and diagnostics.
    public var displayName: String {
        switch self {
        case .twitter: return "Twitter/X"
        case .reddit: return "Reddit"
        case .youtube: return "YouTube"
        case .github: return "GitHub"
        case .bilibili: return "Bilibili"
        case .facebook: return "Facebook"
        case .instagram: return "Instagram"
        case .linkedin: return "LinkedIn"
        case .xiaohongshu: return "Xiaohongshu"
        case .v2ex: return "V2EX"
        }
    }

    /// Public domains used to scope discovery for this platform.
    public var searchDomains: [String] {
        switch self {
        case .twitter: return ["x.com", "twitter.com"]
        case .reddit: return ["reddit.com"]
        case .youtube: return ["youtube.com", "youtu.be"]
        case .github: return ["github.com"]
        case .bilibili: return ["bilibili.com"]
        case .facebook: return ["facebook.com"]
        case .instagram: return ["instagram.com"]
        case .linkedin: return ["linkedin.com"]
        case .xiaohongshu: return ["xiaohongshu.com", "xhslink.com"]
        case .v2ex: return ["v2ex.com"]
        }
    }

    /// Creates a platform from a user- or agent-facing identifier.
    public init?(identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")

        switch normalized {
        case "twitter", "x", "twitterx", "xtwitter": self = .twitter
        case "reddit": self = .reddit
        case "youtube", "yt": self = .youtube
        case "github", "gh": self = .github
        case "bilibili", "bili", "b站": self = .bilibili
        case "facebook", "fb": self = .facebook
        case "instagram", "ig": self = .instagram
        case "linkedin": self = .linkedin
        case "xiaohongshu", "xhs", "littleredbook": self = .xiaohongshu
        case "v2ex": self = .v2ex
        default: return nil
        }
    }

    /// Returns the platform owning a public URL host, when it is recognized.
    public static func platform(for url: URL) -> SocialPlatform? {
        guard let host = url.host?.lowercased() else { return nil }

        return allCases.first { platform in
            platform.searchDomains.contains { domain in
                host == domain || host.hasSuffix("." + domain)
            }
        }
    }
}
