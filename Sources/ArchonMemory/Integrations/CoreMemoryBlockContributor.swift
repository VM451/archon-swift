import ArchonContext
import Foundation

/// Explicit user consent scoping which working-memory keys may enter
/// request-scoped context assembly. Key filtering is enforced by
/// `CoreMemoryBlockContributor`; fetching the correctly scoped blocks stays
/// host-owned through `ArchonClient.coreBlock(userId:)`.
public struct MemoryBlockConsent: Codable, Equatable, Sendable {
    public let userId: String?
    public let consentedKeys: Set<String>
    public let grantedAt: Date

    public init(
        userId: String? = nil,
        consentedKeys: Set<String>,
        grantedAt: Date = Date()
    ) {
        self.userId = userId
        self.consentedKeys = consentedKeys
        self.grantedAt = grantedAt
    }
}

public enum MemoryBlockContributorError: Error, LocalizedError, Equatable, Sendable {
    case noConsentedContent

    public var errorDescription: String? {
        switch self {
        case .noConsentedContent:
            "No consented core-memory keys are available for context assembly."
        }
    }
}

/// A `ContextContributor` bridge over `CoreMemoryBlock` working memory.
///
/// Only consented keys are emitted, sorted for deterministic assembly, with a
/// stable contributor identity and explicit provenance. An empty effective key
/// set fails closed instead of contributing silent empty context.
public struct CoreMemoryBlockContributor: ContextContributor, Sendable {
    public static let contributorID = "archon.memory.core-blocks"

    public let id: String
    private let blocks: CoreMemoryBlock
    private let consent: MemoryBlockConsent
    private let priority: Int
    private let trust: ContextTrust

    public init(
        blocks: CoreMemoryBlock,
        consent: MemoryBlockConsent,
        priority: Int = 100,
        trust: ContextTrust = .unknown
    ) {
        self.id = Self.contributorID
        self.blocks = blocks
        self.consent = consent
        self.priority = priority
        self.trust = trust
    }

    public func makeContextFragment() async throws -> ContextFragment {
        let keys = blocks.blocks.keys
            .filter { consent.consentedKeys.contains($0) }
            .sorted()
        guard !keys.isEmpty else {
            throw MemoryBlockContributorError.noConsentedContent
        }
        var metadata = ["archon.memory.keys": keys.joined(separator: ",")]
        if let userId = consent.userId {
            metadata["archon.memory.userId"] = userId
        }
        return ContextFragment(
            id: Self.contributorID,
            source: Self.contributorID,
            content: keys.map { "\($0): \(blocks.blocks[$0] ?? "")" }.joined(separator: "\n"),
            priority: priority,
            metadata: metadata,
            provenance: Self.contributorID,
            trust: trust
        )
    }
}

extension ArchonClient {
    /// Builds a consent-scoped contributor over this client's stored working
    /// blocks for `consent.userId`. Consent itself is host-supplied; this
    /// helper only fetches the matching scope and binds it to the consent.
    public func coreBlockContributor(
        consent: MemoryBlockConsent,
        priority: Int = 100,
        trust: ContextTrust = .unknown
    ) async throws -> CoreMemoryBlockContributor {
        let stored = try await coreBlock(userId: consent.userId)
        return CoreMemoryBlockContributor(
            blocks: CoreMemoryBlock(blocks: stored),
            consent: consent,
            priority: priority,
            trust: trust
        )
    }
}
