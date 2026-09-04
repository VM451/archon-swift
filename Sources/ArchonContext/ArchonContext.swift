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

public struct ContextSnapshot: Codable, Equatable, Sendable {
    public let fragments: [ContextFragment]
    public let createdAt: Date

    public init(fragments: [ContextFragment], createdAt: Date = Date()) {
        self.fragments = fragments
        self.createdAt = createdAt
    }

    public var assembledText: String {
        fragments
            .sorted { $0.priority > $1.priority }
            .map { "[\($0.source)]\n\($0.content)" }
            .joined(separator: "\n\n")
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

    public func snapshot() async throws -> ContextSnapshot {
        let orderedContributors = contributors.values.sorted { $0.id < $1.id }
        var fragments: [ContextFragment] = []
        for contributor in orderedContributors {
            try Task.checkCancellation()
            fragments.append(try await contributor.makeContextFragment())
        }
        return ContextSnapshot(fragments: fragments)
    }
}
