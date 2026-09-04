import Foundation
import ArchonCore

public struct ContextFragment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let content: String
    public let priority: Int
    public let metadata: [String: String]

    public init(id: String = UUID().uuidString, source: String, content: String, priority: Int = 0, metadata: [String: String] = [:]) {
        self.id = id
        self.source = source
        self.content = content
        self.priority = priority
        self.metadata = metadata
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

    public init(maxUTF8Bytes: Int? = nil, maxFragments: Int? = nil) throws {
        if let maxUTF8Bytes, maxUTF8Bytes < 0 {
            throw ContextBuilderError.invalidBudget
        }
        if let maxFragments, maxFragments < 0 {
            throw ContextBuilderError.invalidBudget
        }
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxFragments = maxFragments
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

/// Builds current request context. It deliberately does not persist memory or execute actions.
public actor ContextBuilder {
    private var contributors: [String: any ContextContributor] = [:]

    public init(contributors: [any ContextContributor] = []) {
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
        var fragments: [ContextFragment] = []
        for contributor in orderedContributors {
            try Task.checkCancellation()
            fragments.append(try await contributor.makeContextFragment())
        }
        try Task.checkCancellation()
        return ContextSnapshot(
            fragments: Self.apply(budget: budget, to: fragments)
        )
    }

    private static func apply(
        budget: ContextBudget?,
        to fragments: [ContextFragment]
    ) -> [ContextFragment] {
        guard let budget,
              budget.maxUTF8Bytes != nil || budget.maxFragments != nil
        else {
            return fragments
        }

        let ordered = ContextSnapshot(fragments: fragments).fragments
        var result: [ContextFragment] = []
        result.reserveCapacity(min(ordered.count, budget.maxFragments ?? ordered.count))
        var usedBytes = 0

        for fragment in ordered {
            if let maxFragments = budget.maxFragments,
               result.count >= maxFragments {
                break
            }

            let separator = result.isEmpty ? "" : "\n\n"
            let header = "[\(fragment.source)]\n"
            let fullContent = fragment.content
            guard let maxBytes = budget.maxUTF8Bytes else {
                result.append(fragment)
                continue
            }

            let available = maxBytes - usedBytes - separator.utf8.count
            guard available >= header.utf8.count else { break }
            let contentBudget = available - header.utf8.count
            let content = Self.prefix(fullContent, maxUTF8Bytes: contentBudget)
            result.append(
                ContextFragment(
                    id: fragment.id,
                    source: fragment.source,
                    content: content,
                    priority: fragment.priority,
                    metadata: fragment.metadata
                )
            )
            usedBytes += separator.utf8.count + header.utf8.count + content.utf8.count
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
}
