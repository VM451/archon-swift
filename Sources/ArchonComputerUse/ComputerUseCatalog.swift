import Foundation
import ArchonCore

/// A host-authored description of one semantic action, without coordinates.
///
/// Descriptors are data: the host executes through `SemanticAction` closures
/// registered on `ComputerUseController`. IDs follow the same allowlist as
/// `ComputerUseExecutionLimits`; risks of `.modify` and above require a
/// postcondition (see `requiresPostcondition`).
public struct SemanticActionDescriptor: Sendable, Equatable {
    public var id: String
    public var description: String
    public var risk: ComputerUseRisk
    /// Semantic role the target surface must expose (for example `"button"`).
    /// Registration installs a precondition that fails closed (stale target)
    /// when no current element carries this role.
    public var targetRole: String?
    /// Marks actions whose policy must issue an explicit short-lived
    /// `ComputerUseApproval`. Enforcement stays in
    /// `ComputerUsePermissionPolicy`; the controller already requires a valid
    /// approval for every execution.
    public var requiresApproval: Bool
    /// Postcondition identifier resolved through the `verifiers` passed to
    /// `ComputerUseCatalog.register(on:execute:verifiers:)`.
    public var postconditionID: String?

    public init(
        id: String,
        description: String,
        risk: ComputerUseRisk,
        targetRole: String? = nil,
        requiresApproval: Bool = false,
        postconditionID: String? = nil
    ) {
        self.id = id
        self.description = description
        self.risk = risk
        self.targetRole = targetRole
        self.requiresApproval = requiresApproval
        self.postconditionID = postconditionID
    }

    /// Fail-closed flag: modify and above must verify their outcome.
    public var requiresPostcondition: Bool {
        switch risk {
        case .modify, .sensitive, .destructive, .external:
            return true
        case .read, .navigate:
            return false
        }
    }
}

/// A named postcondition resolved by ID during catalog registration.
public struct ComputerUsePostcondition: Sendable {
    public let id: String
    public let verify: @Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool

    public init(
        id: String,
        verify: @escaping @Sendable (SemanticActionResult, SemanticSnapshot?) async -> Bool
    ) {
        self.id = id
        self.verify = verify
    }
}

/// Maps host App Intent identifiers to semantic action descriptors. The host
/// executes intents itself; Archon only registers the semantic surface.
///
/// ```swift
/// struct MyIntentBridge: ComputerUseAppIntentBridge {
///     func descriptor(for intentID: String) -> SemanticActionDescriptor? {
///         guard intentID == "OpenInboxIntent" else { return nil }
///         return SemanticActionDescriptor(
///             id: "inbox.open", description: "Open the inbox",
///             risk: .navigate, requiresApproval: false
///         )
///     }
/// }
/// let catalog = ComputerUseCatalog(bridging: MyIntentBridge(), intentIDs: ["OpenInboxIntent"])
/// ```
public protocol ComputerUseAppIntentBridge: Sendable {
    func descriptor(for intentID: String) -> SemanticActionDescriptor?
}

/// A richer semantic action catalog registered onto a controller in one call.
///
/// Registration is fail-closed per descriptor: invalid IDs and modify+
/// descriptors without a resolvable postcondition are refused (reported as
/// `false`, or thrown as `ComputerUseError.invalidDescriptor` by the throwing
/// variant) without touching already-registered actions.
public struct ComputerUseCatalog: Sendable {
    public var actions: [SemanticActionDescriptor]

    public init(actions: [SemanticActionDescriptor] = []) {
        self.actions = actions
    }

    /// Builds a catalog by mapping App Intent identifiers through a bridge.
    /// Unknown intent IDs are skipped (fail closed, never synthesized).
    public init(bridging bridge: any ComputerUseAppIntentBridge, intentIDs: [String]) {
        self.actions = intentIDs.compactMap { bridge.descriptor(for: $0) }
    }

    /// Registers every descriptor, returning per-ID success. `execute`
    /// receives the descriptor so one host closure can serve the catalog;
    /// `verifiers` resolves `postconditionID` values to verify closures.
    @discardableResult
    public func register(
        on controller: ComputerUseController,
        execute: @escaping @Sendable (SemanticActionDescriptor) async throws -> SemanticActionResult,
        verifiers: [String: ComputerUsePostcondition] = [:]
    ) async -> [String: Bool] {
        var outcomes: [String: Bool] = [:]
        for descriptor in actions {
            let verify = descriptor.postconditionID.flatMap { verifiers[$0]?.verify }
            let descriptorCopy = descriptor
            outcomes[descriptor.id] = await controller.register(
                descriptor: descriptorCopy,
                execute: { try await execute(descriptorCopy) },
                verify: verify
            )
        }
        return outcomes
    }

    /// Throwing variant: throws `ComputerUseError.invalidDescriptor` for the
    /// first refused descriptor after registering the preceding ones.
    public func registerOrThrow(
        on controller: ComputerUseController,
        execute: @escaping @Sendable (SemanticActionDescriptor) async throws -> SemanticActionResult,
        verifiers: [String: ComputerUsePostcondition] = [:]
    ) async throws {
        for descriptor in actions {
            let verify = descriptor.postconditionID.flatMap { verifiers[$0]?.verify }
            let descriptorCopy = descriptor
            let registered = await controller.register(
                descriptor: descriptorCopy,
                execute: { try await execute(descriptorCopy) },
                verify: verify
            )
            guard registered else {
                throw ComputerUseError.invalidDescriptor(descriptor.id)
            }
        }
    }
}
