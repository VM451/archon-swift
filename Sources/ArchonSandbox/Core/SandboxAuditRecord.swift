import Foundation
import ArchonCore

/// Outcome of a sandboxed capability decision or audited operation.
public enum SandboxAuditOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    case allowed
    case denied
    case error
}

/// An auditable sandbox decision pairing the emitted event with its policy
/// outcome and the capability under evaluation, if any.
public struct SandboxAuditRecord: Sendable, Equatable {
    public var event: SandboxEvent
    public var outcome: SandboxAuditOutcome
    public var capability: ArchonPermission?
    public var recordedAt: Date

    public init(
        event: SandboxEvent,
        outcome: SandboxAuditOutcome,
        capability: ArchonPermission? = nil,
        recordedAt: Date = Date()
    ) {
        self.event = event
        self.outcome = outcome
        self.capability = capability
        self.recordedAt = recordedAt
    }
}

/// Pure, WebKit-free filter logic backing the developer overlay audit tab.
public struct SandboxAuditFilter: Sendable, Equatable {
    public var outcome: SandboxAuditOutcome?
    public var capability: ArchonPermission?

    public init(outcome: SandboxAuditOutcome? = nil, capability: ArchonPermission? = nil) {
        self.outcome = outcome
        self.capability = capability
    }

    public static let all = SandboxAuditFilter()

    public func matches(_ record: SandboxAuditRecord) -> Bool {
        if let outcome, record.outcome != outcome { return false }
        if let capability, record.capability != capability { return false }
        return true
    }

    public func apply(to records: [SandboxAuditRecord]) -> [SandboxAuditRecord] {
        records.filter(matches)
    }
}
