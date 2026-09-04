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

    public init(screenID: String, elements: [SemanticElement], capturedAt: Date = Date()) {
        self.screenID = screenID
        self.elements = elements
        self.capturedAt = capturedAt
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
    public let execute: @Sendable () async throws -> SemanticActionResult
    /// Optional host-defined postcondition. It receives the action result and
    /// the fresh post-action semantic snapshot, if observation is available.
    public let verify: (@Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool)?

    public init(
        id: String,
        description: String,
        risk: ComputerUseRisk,
        targetElementID: String? = nil,
        verify: (@Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool)? = nil,
        execute: @escaping @Sendable () async throws -> SemanticActionResult
    ) {
        self.id = id
        self.description = description
        self.risk = risk
        self.targetElementID = targetElementID
        self.verify = verify
        self.execute = execute
    }
}

public protocol ComputerUseObservationProvider: Sendable {
    func captureSnapshot() async throws -> SemanticSnapshot
}

public protocol ComputerUsePermissionPolicy: Sendable {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool
}

public struct ReadOnlyComputerUsePolicy: ComputerUsePermissionPolicy, Sendable {
    public init() {}
    public func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool {
        risk == .read || risk == .navigate
    }
}

public enum ComputerUseSessionState: String, Codable, Sendable {
    case idle
    case observing
    case executing
    case paused
    case stopped
}

public enum ComputerUseError: Error, LocalizedError, Equatable, Sendable {
    case actionNotFound(String)
    case permissionDenied(String)
    case observationUnavailable
    case verificationFailed(String)
    case actionCancelled(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .actionNotFound(let id): "Computer-use action not found: \(id)"
        case .permissionDenied(let id): "Computer-use permission denied: \(id)"
        case .observationUnavailable: "Computer-use action requires a semantic observation provider."
        case .verificationFailed(let id): "Computer-use verification failed: \(id)"
        case .actionCancelled(let id): "Computer-use action was cancelled: \(id)"
        case .stopped: "Computer-use execution was stopped."
        }
    }
}

/// Semantic-first host-app action registry. It never issues device-wide coordinate events.
public actor ComputerUseController {
    private let observationProvider: (any ComputerUseObservationProvider)?
    private let permissionPolicy: any ComputerUsePermissionPolicy
    private var actions: [String: SemanticAction] = [:]
    private var currentTask: Task<SemanticActionResult, Error>?
    private var currentExecutionID: UUID?
    public private(set) var lastSnapshot: SemanticSnapshot?
    public private(set) var state: ComputerUseSessionState = .idle

    public init(
        observationProvider: (any ComputerUseObservationProvider)? = nil,
        permissionPolicy: any ComputerUsePermissionPolicy = ReadOnlyComputerUsePolicy()
    ) {
        self.observationProvider = observationProvider
        self.permissionPolicy = permissionPolicy
    }

    public func register(_ action: SemanticAction) {
        actions[action.id] = action
    }

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
            lastSnapshot = snapshot
            if state == .observing { state = .idle }
            return snapshot
        } catch {
            if state == .observing { state = .idle }
            throw error
        }
    }

    public func execute(actionID: String) async throws -> SemanticActionResult {
        guard let action = actions[actionID] else { throw ComputerUseError.actionNotFound(actionID) }
        guard await permissionPolicy.allows(action.risk, action: action) else { throw ComputerUseError.permissionDenied(actionID) }

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
                throw ComputerUseError.verificationFailed(actionID)
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
}
