import Testing
import Foundation
@testable import ArchonSearch

@Suite("Social Discovery Contract Tests")
struct SocialDiscoveryTests {
    private let expectedPlatforms: [SocialPlatform] = [
        .twitter,
        .reddit,
        .youtube,
        .github,
        .bilibili,
        .facebook,
        .instagram,
        .linkedin,
        .xiaohongshu,
        .v2ex
    ]

    @Test("SocialPlatform exposes the frozen cases and value conformances")
    func socialPlatformCasesAndConformances() throws {
        #expect(SocialPlatform.allCases == expectedPlatforms)
        #expect(Set(SocialPlatform.allCases).count == expectedPlatforms.count)

        for platform in expectedPlatforms {
            #expect(!platform.displayName.isEmpty)
            #expect(!platform.searchDomains.isEmpty)

            let encoded = try JSONEncoder().encode(platform)
            let decoded = try JSONDecoder().decode(SocialPlatform.self, from: encoded)
            #expect(decoded == platform)

            let sendableValue = acceptSendable(platform)
            #expect(sendableValue == platform)
        }

        #expect(SocialPlatform.twitter.searchDomains.contains("x.com"))
        #expect(SocialPlatform.twitter.searchDomains.contains("twitter.com"))
        #expect(SocialPlatform.reddit.searchDomains.contains("reddit.com"))
        #expect(SocialPlatform.youtube.searchDomains.contains("youtube.com"))
        #expect(SocialPlatform.github.searchDomains.contains("github.com"))
        #expect(SocialPlatform.bilibili.searchDomains.contains("bilibili.com"))
        #expect(SocialPlatform.facebook.searchDomains.contains("facebook.com"))
        #expect(SocialPlatform.instagram.searchDomains.contains("instagram.com"))
        #expect(SocialPlatform.linkedin.searchDomains.contains("linkedin.com"))
        #expect(SocialPlatform.xiaohongshu.searchDomains.contains("xiaohongshu.com"))
        #expect(SocialPlatform.v2ex.searchDomains.contains("v2ex.com"))
    }

    @Test("SocialPlatform resolves canonical identifiers and required aliases")
    func socialPlatformIdentifiers() {
        let identifiers: [(String, SocialPlatform)] = [
            ("twitter", .twitter),
            ("x", .twitter),
            ("reddit", .reddit),
            ("youtube", .youtube),
            ("github", .github),
            ("bilibili", .bilibili),
            ("facebook", .facebook),
            ("instagram", .instagram),
            ("linkedin", .linkedin),
            ("xiaohongshu", .xiaohongshu),
            ("v2ex", .v2ex)
        ]

        for (identifier, expectedPlatform) in identifiers {
            #expect(SocialPlatform(identifier: identifier) == expectedPlatform)
        }

        #expect(SocialPlatform(identifier: "not-a-platform") == nil)
    }

    @Test("SocialPlatform recognizes canonical public hosts")
    func socialPlatformHostMatching() {
        #expect(SocialPlatform.platform(for: URL(string: "https://x.com/archon/status/1")!) == .twitter)
        #expect(SocialPlatform.platform(for: URL(string: "https://www.reddit.com/r/swift")!) == .reddit)
        #expect(SocialPlatform.platform(for: URL(string: "https://youtu.be/video")!) == .youtube)
        #expect(SocialPlatform.platform(for: URL(string: "https://github.com/apple/swift")!) == .github)
        #expect(SocialPlatform.platform(for: URL(string: "https://www.bilibili.com/video/BV1")!) == .bilibili)
        #expect(SocialPlatform.platform(for: URL(string: "https://example.com/article")!) == nil)
    }

    @Test("DiscoverySource preserves social media platform selections")
    func socialMediaDiscoverySource() {
        let platforms: [SocialPlatform] = [.twitter, .reddit, .youtube]
        let source = DiscoverySource.socialMedia(platforms: platforms)

        guard case let .socialMedia(actualPlatforms) = source else {
            #expect(Bool(false), "Expected the socialMedia discovery source case")
            return
        }

        #expect(actualPlatforms == platforms)
    }

    @Test("Social search queries include every platform domain and the query")
    func socialSearchQueries() {
        let query = "swift concurrency"

        for platform in SocialPlatform.allCases {
            let searchQuery = DiscoveryEngine.socialSearchQuery(for: platform, query: query)

            #expect(searchQuery.localizedCaseInsensitiveContains(query))
            for domain in platform.searchDomains {
                #expect(searchQuery.localizedCaseInsensitiveContains(domain))
            }
        }
    }

    @Test("URL harvesting retains supported social URLs")
    func harvestSupportedSocialURLs() {
        let text = """
        [X](https://x.com/archon/status/1)
        [Reddit](https://reddit.com/r/swift/)
        [YouTube](https://youtube.com/watch?v=swift)
        [GitHub](https://github.com/apple/swift)
        """
        let currentURL = URL(string: "https://example.com/article")!
        let search = ArchonSearch()
        let harvestedURLs = search.harvestURLs(from: text, currentURL: currentURL)

        let expectedURLs: Set<URL> = [
            URL(string: "https://x.com/archon/status/1")!,
            URL(string: "https://reddit.com/r/swift/")!,
            URL(string: "https://youtube.com/watch?v=swift")!,
            URL(string: "https://github.com/apple/swift")!
        ]

        #expect(Set(harvestedURLs) == expectedURLs)
    }

    private func acceptSendable<T: Sendable>(_ value: T) -> T {
        value
    }
}
