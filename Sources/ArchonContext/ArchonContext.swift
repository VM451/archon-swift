import Foundation
import ArchonCore

public enum ContextTrust: String, Codable, CaseIterable, Sendable {
    case trusted
    case untrusted
    case unknown
}

public struct ContextFragment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let content: String
    public let priority: Int
    public let metadata: [String: String]
    public let provenance: String?
    public let trust: ContextTrust

    public init(
        id: String = UUID().uuidString,
        source: String,
        content: String,
        priority: Int = 0,
        metadata: [String: String] = [:],
        provenance: String? = nil,
        trust: ContextTrust = .unknown
    ) {
        self.id = id
        self.source = source
        self.content = content
        self.priority = priority
        self.metadata = metadata
        self.provenance = provenance
        self.trust = trust
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, content, priority, metadata, provenance, trust
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.source = try container.decode(String.self, forKey: .source)
        self.content = try container.decode(String.self, forKey: .content)
        self.priority = try container.decode(Int.self, forKey: .priority)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.provenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        self.trust = try container.decodeIfPresent(ContextTrust.self, forKey: .trust) ?? .unknown
    }
}

/// Bounds applied when assembling request-scoped context.
///
/// The byte budget is measured on the UTF-8 representation of the final
/// assembled text. The builder includes fragments in descending priority order
/// and truncates only the final included fragment when necessary. It never
/// persists or mutates the underlying contributor data.
public struct ContextBudget: Equatable, Sendable {
    public let maxUTF8Bytes: Int?
    public let maxFragments: Int?
    public let maxTokens: Int?

    public init(maxUTF8Bytes: Int? = nil, maxFragments: Int? = nil, maxTokens: Int? = nil) throws {
        if let maxUTF8Bytes, maxUTF8Bytes < 0 {
            throw ContextBuilderError.invalidBudget
        }
        if let maxFragments, maxFragments < 0 {
            throw ContextBuilderError.invalidBudget
        }
        if let maxTokens, maxTokens < 0 {
            throw ContextBuilderError.invalidBudget
        }
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxFragments = maxFragments
        self.maxTokens = maxTokens
    }
}

public enum ContextBuilderError: Error, LocalizedError, Equatable, Sendable {
    case invalidBudget

    public var errorDescription: String? {
        switch self {
        case .invalidBudget:
            "Context budgets must use non-negative limits."
        }
    }
}

public struct ContextSnapshot: Codable, Equatable, Sendable {
    public let fragments: [ContextFragment]
    public let createdAt: Date

    public init(fragments: [ContextFragment], createdAt: Date = Date()) {
        self.fragments = Self.ordered(fragments)
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fragments: container.decode([ContextFragment].self, forKey: .fragments),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    public var assembledText: String {
        fragments
            .map { "[\($0.source)]\n\($0.content)" }
            .joined(separator: "\n\n")
    }

    private enum CodingKeys: String, CodingKey {
        case fragments
        case createdAt
    }

    private static func ordered(_ fragments: [ContextFragment]) -> [ContextFragment] {
        fragments.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            if $0.id != $1.id {
                return $0.id < $1.id
            }
            return $0.source < $1.source
        }
    }
}

public protocol ContextContributor: Sendable {
    var id: String { get }
    func makeContextFragment() async throws -> ContextFragment
}

public protocol ContextTokenEstimator: Sendable {
    func estimateTokens(_ text: String) -> Int
}

/// A deterministic, dependency-free fallback estimator. Hosts can inject a
/// model-family tokenizer when exact token accounting is available.
public struct UTF8ContextTokenEstimator: ContextTokenEstimator, Sendable {
    public init() {}

    public func estimateTokens(_ text: String) -> Int {
        max(0, (text.utf8.count + 3) / 4)
    }
}

/// Builds current request context. It deliberately does not persist memory or execute actions.
public actor ContextBuilder {
    private var contributors: [String: any ContextContributor] = [:]
    private let tokenEstimator: any ContextTokenEstimator

    public init(
        contributors: [any ContextContributor] = [],
        tokenEstimator: any ContextTokenEstimator = UTF8ContextTokenEstimator()
    ) {
        self.tokenEstimator = tokenEstimator
        for contributor in contributors { self.contributors[contributor.id] = contributor }
    }

    public func register(_ contributor: any ContextContributor) {
        contributors[contributor.id] = contributor
    }

    public func removeContributor(id: String) {
        contributors.removeValue(forKey: id)
    }

    public func snapshot(budget: ContextBudget? = nil) async throws -> ContextSnapshot {
        let orderedContributors = contributors.values.sorted { $0.id < $1.id }
        let fragments = try await withThrowingTaskGroup(of: ContextFragment.self, returning: [ContextFragment].self) { group in
            for contributor in orderedContributors {
                group.addTask {
                    try Task.checkCancellation()
                    return try await contributor.makeContextFragment()
                }
            }

            var fragments: [ContextFragment] = []
            fragments.reserveCapacity(orderedContributors.count)
            for try await fragment in group {
                fragments.append(fragment)
            }
            return fragments
        }
        try Task.checkCancellation()
        return ContextSnapshot(
            fragments: Self.apply(budget: budget, to: fragments, tokenEstimator: tokenEstimator)
        )
    }

    private static func apply(
        budget: ContextBudget?,
        to fragments: [ContextFragment],
        tokenEstimator: any ContextTokenEstimator
    ) -> [ContextFragment] {
        guard let budget,
              budget.maxUTF8Bytes != nil || budget.maxFragments != nil || budget.maxTokens != nil
        else {
            return fragments
        }

        let ordered = ContextSnapshot(fragments: fragments).fragments
        var result: [ContextFragment] = []
        result.reserveCapacity(min(ordered.count, budget.maxFragments ?? ordered.count))
        var usedBytes = 0
        var usedTokens = 0

        for fragment in ordered {
            if let maxFragments = budget.maxFragments,
               result.count >= maxFragments {
                break
            }

            let separator = result.isEmpty ? "" : "\n\n"
            let header = "[\(fragment.source)]\n"
            let fullContent = fragment.content
            var content = fullContent
            if let maxBytes = budget.maxUTF8Bytes {
                let available = maxBytes - usedBytes - separator.utf8.count - header.utf8.count
                guard available >= 0 else { break }
                content = Self.prefix(content, maxUTF8Bytes: available)
            }
            if let maxTokens = budget.maxTokens {
                let overhead = tokenEstimator.estimateTokens(separator + header)
                let available = maxTokens - usedTokens - overhead
                guard available >= 0 else { break }
                content = Self.prefix(content, maxTokens: available, estimator: tokenEstimator)
            }

            let addedBytes = separator.utf8.count + header.utf8.count + content.utf8.count
            let addedTokens = tokenEstimator.estimateTokens(separator + header + content)
            if let maxBytes = budget.maxUTF8Bytes, usedBytes + addedBytes > maxBytes { break }
            if let maxTokens = budget.maxTokens, usedTokens + addedTokens > maxTokens { break }
            result.append(
                ContextFragment(
                    id: fragment.id,
                    source: fragment.source,
                    content: content,
                    priority: fragment.priority,
                    metadata: fragment.metadata.merging(
                        content == fullContent ? [:] : ["archon.truncated": "true"]
                    ) { _, new in new },
                    provenance: fragment.provenance,
                    trust: fragment.trust
                )
            )
            usedBytes += addedBytes
            usedTokens += addedTokens
            if content.utf8.count < fullContent.utf8.count {
                break
            }
        }
        return result
    }

    private static func prefix(_ value: String, maxUTF8Bytes: Int) -> String {
        guard maxUTF8Bytes > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maxUTF8Bytes))
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maxUTF8Bytes else { break }
            result = candidate
        }
        return result
    }

    private static func prefix(
        _ value: String,
        maxTokens: Int,
        estimator: any ContextTokenEstimator
    ) -> String {
        guard maxTokens > 0 else { return "" }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard estimator.estimateTokens(candidate) <= maxTokens else { break }
            result = candidate
        }
        return result
    }
}
