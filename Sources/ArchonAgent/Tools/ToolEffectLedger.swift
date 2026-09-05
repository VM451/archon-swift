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

public protocol ToolEffectLedger: Sendable {
    func receipt(for callID: String) async throws -> ToolEffectReceipt?
    func record(_ receipt: ToolEffectReceipt) async throws
}

public actor InMemoryToolEffectLedger: ToolEffectLedger {
    private var receipts: [String: ToolEffectReceipt] = [:]

    public init() {}

    public func receipt(for callID: String) async throws -> ToolEffectReceipt? {
        receipts[callID]
    }

    public func record(_ receipt: ToolEffectReceipt) async throws {
        receipts[receipt.callID] = receipt
    }
}
