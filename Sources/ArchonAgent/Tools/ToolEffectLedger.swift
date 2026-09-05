import Foundation

/// A durable-boundary receipt for a tool call. The call identifier must be
/// stable across checkpoint recovery when the host wants exactly-once replay.
public struct ToolEffectReceipt: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let output: String
    public let recordedAt: Date

    public init(
        callID: String,
        toolName: String,
        output: String,
        recordedAt: Date = Date()
    ) {
        self.callID = callID
        self.toolName = toolName
        self.output = output
        self.recordedAt = recordedAt
    }
}

/// The result of atomically reserving a stable tool-call identifier.
public enum ToolEffectReservation: Sendable {
    case execute
    case replay(ToolEffectReceipt)
    case inFlight
}

public protocol ToolEffectLedger: Sendable {
    /// Atomically claims a call ID so concurrent retries cannot execute the
    /// same side effect more than once in this process or durable store.
    func reserve(callID: String, toolName: String) async throws -> ToolEffectReservation
    /// Commits the receipt for a previously reserved call ID.
    func record(_ receipt: ToolEffectReceipt) async throws
    /// Releases a reservation when the tool did not execute.
    func release(callID: String) async throws
}

public actor InMemoryToolEffectLedger: ToolEffectLedger {
    private var receipts: [String: ToolEffectReceipt] = [:]
    private var inFlight: Set<String> = []

    public init() {}

    public func reserve(callID: String, toolName: String) async throws -> ToolEffectReservation {
        if let receipt = receipts[callID] {
            guard receipt.toolName == toolName else {
                throw ToolEffectLedgerError.callIDCollision(callID: callID)
            }
            return .replay(receipt)
        }
        guard inFlight.insert(callID).inserted else {
            return .inFlight
        }
        return .execute
    }

    public func record(_ receipt: ToolEffectReceipt) async throws {
        guard inFlight.contains(receipt.callID) || receipts[receipt.callID] != nil else {
            throw ToolEffectLedgerError.unreservedCall(receipt.callID)
        }
        receipts[receipt.callID] = receipt
        inFlight.remove(receipt.callID)
    }

    public func release(callID: String) async throws {
        inFlight.remove(callID)
    }
}

public enum ToolEffectLedgerError: Error, LocalizedError, Equatable, Sendable {
    case callIDCollision(callID: String)
    case unreservedCall(String)

    public var errorDescription: String? {
        switch self {
        case .callIDCollision(let callID):
            return "Tool call identifier is already bound to another tool: \(callID)."
        case .unreservedCall(let callID):
            return "Tool call was not reserved before recording: \(callID)."
        }
    }
}
