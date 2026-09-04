import Foundation

/// Thrown within an AgentNode to immediately halt graph execution and request human intervention.
public struct GraphInterrupt: Error, Sendable, Codable, Equatable {
    public let message: String
    public let actionName: String?
    public let payload: [String: String]
    public let isApprovalRequired: Bool

    public init(
        message: String,
        actionName: String? = nil,
        payload: [String: String] = [:],
        isApprovalRequired: Bool = true
    ) {
        self.message = message
        self.actionName = actionName
        self.payload = payload
        self.isApprovalRequired = isApprovalRequired
    }

    public static func approvalRequired(
        message: String,
        actionName: String? = nil,
        payload: [String: String] = [:]
    ) -> GraphInterrupt {
        GraphInterrupt(message: message, actionName: actionName, payload: payload, isApprovalRequired: true)
    }

    public static func clarification(
        question: String
    ) -> GraphInterrupt {
        GraphInterrupt(message: question, isApprovalRequired: false)
    }
}

/// Payload supplied when resuming an interrupted graph.
public struct ResumePayload<State: AgentState>: Sendable {
    public let isApproved: Bool
    public let updatedState: State?
    public let feedback: String?

    public init(
        isApproved: Bool = true,
        updatedState: State? = nil,
        feedback: String? = nil
    ) {
        self.isApproved = isApproved
        self.updatedState = updatedState
        self.feedback = feedback
    }
}

/// Thread-safe manager for tracking active human-in-the-loop requests and approvals.
public actor InterruptManager {
    private var pendingInterrupts: [String: GraphInterrupt] = [:]

    public init() {}

    public func register(threadId: String, interrupt: GraphInterrupt) {
        pendingInterrupts[threadId] = interrupt
    }

    public func getPending(threadId: String) -> GraphInterrupt? {
        pendingInterrupts[threadId]
    }

    public func clear(threadId: String) {
        pendingInterrupts.removeValue(forKey: threadId)
    }
}
