import Foundation
import ArchonCore

public enum ComputerUseRisk: String, Codable, CaseIterable, Sendable {
    case read
    case navigate
    case modify
    case sensitive
    case destructive
    case external
}

public struct SemanticElement: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let label: String
    public let value: String?

    public init(id: String, role: String, label: String, value: String? = nil) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
    }
}

public struct SemanticSnapshot: Codable, Equatable, Sendable {
    public let screenID: String
    public let elements: [SemanticElement]
    public let capturedAt: Date
    public let revision: UInt64

    public init(
        screenID: String,
        elements: [SemanticElement],
        capturedAt: Date = Date(),
        revision: UInt64 = 0
    ) {
        self.screenID = screenID
        self.elements = elements
        self.capturedAt = capturedAt
        self.revision = revision
    }
}

public struct ComputerUseApproval: Codable, Equatable, Sendable {
    public let actionID: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(actionID: String, issuedAt: Date = Date(), expiresAt: Date? = nil) {
        self.actionID = actionID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(300)
    }

    public func isValid(at date: Date = Date()) -> Bool {
        issuedAt <= date && date <= expiresAt
    }
}

public struct SemanticActionResult: Codable, Equatable, Sendable {
    public let actionID: String
    public let succeeded: Bool
    public let message: String

    public init(actionID: String, succeeded: Bool, message: String = "") {
        self.actionID = actionID
        self.succeeded = succeeded
        self.message = message
    }
}

public struct SemanticAction: Sendable, Identifiable {
    public let id: String
    public let description: String
    public let risk: ComputerUseRisk
    public let targetElementID: String?
    public let precondition: (@Sendable (SemanticSnapshot?) async -> Bool)?
    public let execute: @Sendable () async throws -> SemanticActionResult
    /// Optional host-defined postcondition. It receives the action result and
    /// the fresh post-action semantic snapshot, if observation is available.
    public let verify: (@Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool)?

    public init(
        id: String,
        description: String,
        risk: ComputerUseRisk,
        targetElementID: String? = nil,
        precondition: (@Sendable (SemanticSnapshot?) async -> Bool)? = nil,
        verify: (@Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool)? = nil,
        execute: @escaping @Sendable () async throws -> SemanticActionResult
    ) {
        self.id = id
        self.description = description
        self.risk = risk
        self.targetElementID = targetElementID
        self.precondition = precondition
        self.verify = verify
        self.execute = execute
    }
}

public protocol ComputerUseObservationProvider: Sendable {
    func captureSnapshot() async throws -> SemanticSnapshot
}

public protocol ComputerUsePermissionPolicy: Sendable {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool

    func approval(for risk: ComputerUseRisk, action: SemanticAction) async -> ComputerUseApproval?

    /// Governs host-executed visual fallbacks for screens with no semantic
    /// surface. Denied by default: a host opts in explicitly.
    func allowsFallback(_ request: ComputerUseFallbackRequest) async -> Bool
}

public extension ComputerUsePermissionPolicy {
    func approval(for risk: ComputerUseRisk, action: SemanticAction) async -> ComputerUseApproval? {
        guard await allows(risk, action: action) else { return nil }
        return ComputerUseApproval(actionID: action.id)
    }

    func allowsFallback(_ request: ComputerUseFallbackRequest) async -> Bool {
        _ = request
        return false
    }
}

public struct ReadOnlyComputerUsePolicy: ComputerUsePermissionPolicy, Sendable {
    public init() {}
    public func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        risk == .read || risk == .navigate
    }
}

/// A host-executed visual fallback request for screens with no semantic
/// surface. Archon never captures screenshots or issues coordinate taps
/// itself; it validates the request bounds, requires explicit host opt-in
/// through the permission policy, and audits the decision. The host performs
/// the fallback outside Archon and re-observes through the semantic provider.
public struct ComputerUseFallbackRequest: Codable, Equatable, Sendable {
    public let actionID: String
    public let reason: String
    /// Caller-stated uncertainty in 0...1 (higher means less sure). There is
    /// no default: the caller must state how uncertain the fallback is.
    public let uncertainty: Double
    public let maximumAttempts: Int

    public init(
        actionID: String,
        reason: String,
        uncertainty: Double,
        maximumAttempts: Int = 1
    ) {
        self.actionID = actionID
        self.reason = reason
        self.uncertainty = uncertainty
        self.maximumAttempts = maximumAttempts
    }
}

public enum ComputerUseSessionState: String, Codable, Sendable {
    case idle
    case observing
    case executing
    case paused
    case stopped
}

/// Deterministic fail-closed bounds for the semantic controller.
public struct ComputerUseExecutionLimits: Codable, Equatable, Sendable {
    public let maximumActionsPerSession: Int
    public let maximumActionIDLength: Int
    public let maximumElementsPerSnapshot: Int

    public init(
        maximumActionsPerSession: Int = 100,
        maximumActionIDLength: Int = 128,
        maximumElementsPerSnapshot: Int = 1_000
    ) {
        self.maximumActionsPerSession = max(maximumActionsPerSession, 1)
        self.maximumActionIDLength = max(maximumActionIDLength, 1)
        self.maximumElementsPerSnapshot = max(maximumElementsPerSnapshot, 1)
    }

    public static let `default` = ComputerUseExecutionLimits()

    /// Fail-closed action-ID validation: non-empty, bounded length, and drawn
    /// from an explicit allowlist so IDs cannot smuggle paths or expressions.
    public func isValidActionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maximumActionIDLength else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum ComputerUseError: Error, LocalizedError, Equatable, Sendable {
    case actionNotFound(String)
    case permissionDenied(String)
    case observationUnavailable
    case approvalRequired(String)
    case staleObservation(String)
    case verificationFailed(String)
    case actionCancelled(String)
    case limitsExceeded(String)
    case invalidDescriptor(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .actionNotFound(let id): "Computer-use action not found: \(id)"
        case .permissionDenied(let id): "Computer-use permission denied: \(id)"
        case .observationUnavailable: "Computer-use action requires a semantic observation provider."
        case .approvalRequired(let id): "Computer-use action requires an explicit approval: \(id)"
        case .staleObservation(let id): "Computer-use observation became stale before action execution: \(id)"
        case .verificationFailed(let id): "Computer-use verification failed: \(id)"
        case .actionCancelled(let id): "Computer-use action was cancelled: \(id)"
        case .limitsExceeded(let id): "Computer-use execution limit exceeded: \(id)"
        case .invalidDescriptor(let id): "Computer-use descriptor was refused (invalid ID or modify+ action without a postcondition): \(id)"
        case .stopped: "Computer-use execution was stopped."
        }
    }
}

/// Semantic-first host-app action registry. It never issues device-wide coordinate events.
public actor ComputerUseController {
    private let observationProvider: (any ComputerUseObservationProvider)?
    private let permissionPolicy: any ComputerUsePermissionPolicy
    private let auditSink: any ArchonAuditSink
    private var actions: [String: SemanticAction] = [:]
    private var currentTask: Task<SemanticActionResult, Error>?
    private var currentExecutionID: UUID?
    public private(set) var lastSnapshot: SemanticSnapshot?
    public private(set) var state: ComputerUseSessionState = .idle

    private let limits: ComputerUseExecutionLimits
    private var executedActionCount = 0

    public init(
        observationProvider: (any ComputerUseObservationProvider)? = nil,
        permissionPolicy: any ComputerUsePermissionPolicy = ReadOnlyComputerUsePolicy(),
        auditSink: any ArchonAuditSink = NoOpArchonAuditSink(),
        limits: ComputerUseExecutionLimits = .default
    ) {
        self.observationProvider = observationProvider
        self.permissionPolicy = permissionPolicy
        self.auditSink = auditSink
        self.limits = limits
    }

    /// Registers a semantic action. Fail closed: invalid IDs are refused and
    /// report false so untrusted registrations cannot enter the registry.
    @discardableResult
    public func register(_ action: SemanticAction) -> Bool {
        guard limits.isValidActionID(action.id) else { return false }
        actions[action.id] = action
        return true
    }

    /// Registers a catalog descriptor with a host execution closure. Fail
    /// closed: invalid IDs are refused, and modify+ descriptors require a
    /// `verify` postcondition. A `targetRole` installs a precondition that
    /// fails closed as a stale target when no current element carries it.
    @discardableResult
    public func register(
        descriptor: SemanticActionDescriptor,
        execute: @escaping @Sendable () async throws -> SemanticActionResult,
        verify: (@Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool)? = nil
    ) -> Bool {
        guard limits.isValidActionID(descriptor.id) else { return false }
        guard !descriptor.requiresPostcondition || verify != nil else { return false }
        let precondition: (@Sendable (SemanticSnapshot?) async -> Bool)?
        if let targetRole = descriptor.targetRole {
            precondition = { snapshot in
                snapshot?.elements.contains(where: { $0.role == targetRole }) ?? false
            }
        } else {
            precondition = nil
        }
        return register(SemanticAction(
            id: descriptor.id,
            description: descriptor.description,
            risk: descriptor.risk,
            targetElementID: nil,
            precondition: precondition,
            verify: verify,
            execute: execute
        ))
    }

    public func isRegistered(id: String) -> Bool { actions[id] != nil }

    public var executionLimits: ComputerUseExecutionLimits { limits }

    public func removeAction(id: String) {
        actions.removeValue(forKey: id)
    }

    public func availableActions() -> [SemanticAction] {
        actions.values.sorted { $0.id < $1.id }
    }

    /// Starts one registered host-app action through the semantic execution
    /// loop. `execute(actionID:)` remains the lower-level spelling for hosts
    /// that prefer it.
    public func start(actionID: String) async throws -> SemanticActionResult {
        try await execute(actionID: actionID)
    }

    public func observe() async throws -> SemanticSnapshot {
        guard let observationProvider else { throw ComputerUseError.observationUnavailable }
        state = .observing
        do {
            let snapshot = try await observationProvider.captureSnapshot()
            guard snapshot.elements.count <= limits.maximumElementsPerSnapshot else {
                throw ComputerUseError.limitsExceeded("snapshot.\(snapshot.screenID)")
            }
            lastSnapshot = snapshot
            if state == .observing { state = .idle }
            return snapshot
        } catch {
            if state == .observing { state = .idle }
            throw error
        }
    }

    public func execute(actionID: String) async throws -> SemanticActionResult {
        guard limits.isValidActionID(actionID) else { throw ComputerUseError.limitsExceeded(actionID) }
        guard state != .stopped else { throw ComputerUseError.stopped }
        guard executedActionCount < limits.maximumActionsPerSession else {
            throw ComputerUseError.limitsExceeded(actionID)
        }
        guard let action = actions[actionID] else { throw ComputerUseError.actionNotFound(actionID) }
        guard let approval = await permissionPolicy.approval(for: action.risk, action: action), approval.isValid() else {
            await auditSink.record(ArchonAuditEvent(
                category: "computer-use",
                action: actionID,
                outcome: "denied",
                metadata: ["risk": action.risk.rawValue]
            ))
            throw ComputerUseError.permissionDenied(actionID)
        }

        guard currentExecutionID == nil else { throw ComputerUseError.actionCancelled(actionID) }
        let executionID = UUID()
        currentExecutionID = executionID
        defer {
            // `stop()` and `pause()` can run while this actor is suspended.
            // Only the still-current execution may clear its bookkeeping or
            // transition the state back to idle.
            if currentExecutionID == executionID {
                currentExecutionID = nil
                currentTask = nil
                if state == .executing { state = .idle }
            }
        }

        if let targetElementID = action.targetElementID {
            let snapshot = try await observe()
            guard currentExecutionID == executionID, state == .idle else {
                throw ComputerUseError.actionCancelled(actionID)
            }
            guard snapshot.elements.contains(where: { $0.id == targetElementID }) else {
                throw ComputerUseError.staleObservation(actionID)
            }
            guard await action.precondition?(snapshot) ?? true else {
                throw ComputerUseError.staleObservation(actionID)
            }
        } else if let precondition = action.precondition {
            guard await precondition(lastSnapshot) else {
                throw ComputerUseError.staleObservation(actionID)
            }
        }
        state = .executing
        let task = Task { try await action.execute() }
        currentTask = task
        let result = try await task.value
        // Cancellation is cooperative. A host action is allowed to ignore
        // the task's cancellation flag, but it must never be able to report a
        // successful computer-use action after pause/stop or a replacement
        // execution has invalidated this operation.
        guard currentExecutionID == executionID, state == .executing else {
            throw ComputerUseError.actionCancelled(actionID)
        }
        guard result.succeeded else { throw ComputerUseError.verificationFailed(actionID) }

        // Re-observe after every successful host-app action when a semantic
        // observation provider exists. This gives the host a fresh post-action
        // state for verification without guessing coordinates or UI state.
        var postActionSnapshot: SemanticSnapshot?
        if observationProvider != nil {
            do {
                postActionSnapshot = try await observe()
            } catch {
                throw ComputerUseError.verificationFailed(actionID)
            }
            guard currentExecutionID == executionID, state == .idle else {
                throw ComputerUseError.actionCancelled(actionID)
            }
        }
        if let verify = action.verify, !(await verify(result, postActionSnapshot)) {
            throw ComputerUseError.verificationFailed(actionID)
        }
        guard currentExecutionID == executionID else {
            throw ComputerUseError.actionCancelled(actionID)
        }
        guard approval.isValid() else {
            throw ComputerUseError.approvalRequired(actionID)
        }
        executedActionCount += 1
        await auditSink.record(ArchonAuditEvent(
            category: "computer-use",
            action: actionID,
            outcome: "succeeded",
            metadata: ["risk": action.risk.rawValue]
        ))
        return result
    }

    public func pause() {
        guard state == .executing || state == .observing else { return }
        state = .paused
        currentTask?.cancel()
    }

    public func stop() {
        currentTask?.cancel()
        currentTask = nil
        currentExecutionID = nil
        state = .stopped
    }

    public func resume(actionID: String) async throws -> SemanticActionResult {
        guard state == .paused || state == .stopped else { return try await execute(actionID: actionID) }
        state = .idle
        return try await execute(actionID: actionID)
    }

    /// Governs one host-executed visual fallback. Validates bounds, requires
    /// explicit policy opt-in, and audits the decision. The host performs the
    /// fallback itself and re-observes through the semantic provider.
    public func requestFallback(_ request: ComputerUseFallbackRequest) async throws {
        guard limits.isValidActionID(request.actionID) else {
            throw ComputerUseError.limitsExceeded(request.actionID)
        }
        guard request.uncertainty.isFinite,
              (0...1).contains(request.uncertainty),
              request.maximumAttempts >= 1 else {
            throw ComputerUseError.limitsExceeded(request.actionID)
        }
        guard await permissionPolicy.allowsFallback(request) else {
            await auditSink.record(ArchonAuditEvent(
                category: "computer-use",
                action: "fallback.\(request.actionID)",
                outcome: "denied",
                metadata: ["uncertainty": String(request.uncertainty)]
            ))
            throw ComputerUseError.permissionDenied("fallback.\(request.actionID)")
        }
        await auditSink.record(ArchonAuditEvent(
            category: "computer-use",
            action: "fallback.\(request.actionID)",
            outcome: "approved",
            metadata: [
                "uncertainty": String(request.uncertainty),
                "maximumAttempts": String(request.maximumAttempts)
            ]
        ))
    }
}
