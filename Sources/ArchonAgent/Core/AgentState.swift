import Foundation

/// Protocol that every state structure in ArchonAgent must conform to.
/// It must be Sendable, Codable, and Equatable to guarantee strict concurrency safety,
/// deterministic state comparisons, and seamless checkpoint serialization.
public protocol AgentState: Codable, Sendable, Equatable {
    /// Initializes an empty or default instance of the state.
    init()
}

/// A type-erased Sendable and Codable container for partial state updates and
/// dynamic JSON properties.
///
/// This remains source-compatible with the original `Any`-backed API, but
/// decoded collections retain their `AnySendable` elements. That keeps nested
/// values recursively Codable instead of degrading them to `String(describing:)`.
public struct AnySendable: @unchecked Sendable, Codable, Equatable {
    public let value: Any

    public init<T: Sendable & Codable>(_ value: T) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal
        } else if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            self.value = stringVal
        } else if let arrayVal = try? container.decode([AnySendable].self) {
            self.value = arrayVal
        } else if let dictVal = try? container.decode([String: AnySendable].self) {
            self.value = dictVal
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnySendable only supports JSON scalar, array, and object values."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let arrayVal as [AnySendable]:
            try container.encode(arrayVal)
        case let dictVal as [String: AnySendable]:
            try container.encode(dictVal)
        case let codableVal as Encodable:
            let wrapper = EncodableWrapper(codableVal)
            try wrapper.encode(to: encoder)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnySendable only supports JSON scalar, array, and object values."
                )
            )
        }
    }

    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else {
            return false
        }
        return lhsData == rhsData
    }
}

private struct EncodableWrapper: Encodable {
    let value: Encodable

    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// Minimal default empty state for stateless or simple single-turn graphs.
public struct EmptyState: AgentState {
    public init() {}
}

/// Generic dictionary state container for dynamic or schema-less agents.
public struct DictionaryState: AgentState {
    public var storage: [String: String]

    public init() {
        self.storage = [:]
    }

    public init(storage: [String: String]) {
        self.storage = storage
    }

    public subscript(key: String) -> String? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
}
