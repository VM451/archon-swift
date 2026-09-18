import Foundation

/// Structured mutation operation returned by the LLM extraction engine.
public struct MemoryOperation: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case add = "ADD"
        case update = "UPDATE"
        case delete = "DELETE"
        case noChange = "NO_CHANGE"
    }

    public let event: Event
    public let memory: String
    public let oldMemory: String?
    public let id: String? // Target UUID string if UPDATE or DELETE
    public let metadata: [String: String]?

    public init(
        event: Event,
        memory: String,
        oldMemory: String? = nil,
        id: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.event = event
        self.memory = memory
        self.oldMemory = oldMemory
        self.id = id
        self.metadata = metadata
    }
}

/// The structured payload returned by LLM extraction.
public struct StructuredExtractionResponse: Codable, Sendable {
    public let memoryOperations: [MemoryOperation]

    enum CodingKeys: String, CodingKey {
        case memoryOperations = "memory_operations"
    }

    public init(memoryOperations: [MemoryOperation]) {
        self.memoryOperations = memoryOperations
    }
}

/// Result returned from `ArchonClient.add()`.
public struct MemoryChangeset: Codable, Equatable, Sendable {
    public let changes: [MemoryOperation]
    public let affectedItems: [MemoryItem]
    /// Operations skipped with a typed reason. Skips never mutate the store
    /// and never append history; they are recorded here so callers can tell
    /// "nothing to do" apart from "target was invalid".
    public let skipped: [MemoryExtractionSkip]

    public init(
        changes: [MemoryOperation],
        affectedItems: [MemoryItem],
        skipped: [MemoryExtractionSkip] = []
    ) {
        self.changes = changes
        self.affectedItems = affectedItems
        self.skipped = skipped
    }

    enum CodingKeys: String, CodingKey {
        case changes
        case affectedItems
        case skipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.changes = try container.decode([MemoryOperation].self, forKey: .changes)
        self.affectedItems = try container.decode([MemoryItem].self, forKey: .affectedItems)
        self.skipped = try container.decodeIfPresent([MemoryExtractionSkip].self, forKey: .skipped) ?? []
    }
}

/// Why one extraction operation was skipped instead of applied.
public enum MemorySkipReason: Equatable, Sendable {
    /// The operation carried no parsable target UUID.
    case invalidTargetID(String?)
    /// The target record does not exist.
    case targetMissing(UUID)
    /// The target record is soft-deleted.
    case targetDeleted(UUID)
    /// The target chain head expired (`validTo` at or before now) with no
    /// live successor, so updating it would fork the timeline.
    case targetExpired(UUID)
    /// The supersession target is missing, deleted, or expired.
    case supersessionTargetInvalid(UUID)
    /// A `supersededById` pointer dangles or the chain cycles.
    case supersessionChainBroken(UUID)

    /// The typed `ArchonMemoryError` equivalent of this skip.
    public var error: ArchonMemoryError {
        switch self {
        case .invalidTargetID(let raw):
            .invalidConfiguration("Extraction target id is not a UUID: \(raw ?? "nil").")
        case .targetMissing(let id):
            .memoryNotFound(id)
        case .targetDeleted(let id):
            .supersessionTargetInvalid(id)
        case .targetExpired(let id):
            .supersessionTargetInvalid(id)
        case .supersessionTargetInvalid(let id):
            .supersessionTargetInvalid(id)
        case .supersessionChainBroken(let id):
            .supersessionChainBroken(id)
        }
    }

    /// Maps a chain-resolution failure back to a skip reason.
    init(error: ArchonMemoryError, fallbackID: UUID) {
        switch error {
        case .supersessionTargetInvalid(let id):
            self = .supersessionTargetInvalid(id)
        case .supersessionChainBroken(let id):
            self = .supersessionChainBroken(id)
        case .memoryNotFound(let id):
            self = .targetMissing(id)
        default:
            self = .targetMissing(fallbackID)
        }
    }
}

extension MemorySkipReason: Codable {
    enum CodingKeys: String, CodingKey {
        case code
        case id
        case raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        switch code {
        case "invalidTargetID":
            self = .invalidTargetID(try container.decodeIfPresent(String.self, forKey: .raw) ?? nil)
        case "targetMissing":
            self = .targetMissing(try container.decode(UUID.self, forKey: .id))
        case "targetDeleted":
            self = .targetDeleted(try container.decode(UUID.self, forKey: .id))
        case "targetExpired":
            self = .targetExpired(try container.decode(UUID.self, forKey: .id))
        case "supersessionTargetInvalid":
            self = .supersessionTargetInvalid(try container.decode(UUID.self, forKey: .id))
        case "supersessionChainBroken":
            self = .supersessionChainBroken(try container.decode(UUID.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: container,
                debugDescription: "Unknown memory skip reason: \(code)."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invalidTargetID(let raw):
            try container.encode("invalidTargetID", forKey: .code)
            try container.encodeIfPresent(raw, forKey: .raw)
        case .targetMissing(let id):
            try container.encode("targetMissing", forKey: .code)
            try container.encode(id, forKey: .id)
        case .targetDeleted(let id):
            try container.encode("targetDeleted", forKey: .code)
            try container.encode(id, forKey: .id)
        case .targetExpired(let id):
            try container.encode("targetExpired", forKey: .code)
            try container.encode(id, forKey: .id)
        case .supersessionTargetInvalid(let id):
            try container.encode("supersessionTargetInvalid", forKey: .code)
            try container.encode(id, forKey: .id)
        case .supersessionChainBroken(let id):
            try container.encode("supersessionChainBroken", forKey: .code)
            try container.encode(id, forKey: .id)
        }
    }
}

/// One skipped extraction operation with its typed reason.
public struct MemoryExtractionSkip: Codable, Equatable, Sendable {
    public let operation: MemoryOperation
    public let reason: MemorySkipReason

    public init(operation: MemoryOperation, reason: MemorySkipReason) {
        self.operation = operation
        self.reason = reason
    }
}
