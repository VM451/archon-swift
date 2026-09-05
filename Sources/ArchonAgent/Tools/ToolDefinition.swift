import Foundation

/// Defines the OpenAPI / JSON Schema compliant contract for an invocable tool.
public struct ToolDefinition: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let parametersJSONSchema: [String: AnySendable]

    public init(
        name: String,
        description: String,
        parametersJSONSchema: [String: AnySendable] = [
            "type": AnySendable("object"),
            "properties": AnySendable([String: AnySendable]()),
            "required": AnySendable([AnySendable]())
        ]
    ) {
        self.id = name
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }

    /// Validates a JSON argument object against this tool's declared schema.
    /// The validator intentionally implements only the small JSON Schema
    /// subset emitted by Archon tools: object/array primitives, required
    /// fields, enums, properties, items, and `additionalProperties`.
    public func validate(argumentsJSON: String) throws {
        guard !parametersJSONSchema.isEmpty else { return }
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolValidationError.invalidJSON
        }
        guard data.count <= ToolSchemaValidator.maximumInputBytes else {
            throw ToolValidationError.invalidArguments("input exceeds the 1 MiB limit.")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ToolValidationError.invalidJSON
        }
        let schema = ToolSchemaValue.unwrap(parametersJSONSchema)
        guard let schema = schema as? [String: Any] else {
            throw ToolValidationError.invalidSchema("root schema must be a JSON object")
        }
        try ToolSchemaValidator.validate(value: value, schema: schema, path: name)
    }
}

public enum ToolValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidJSON
    case invalidSchema(String)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Tool arguments are not valid JSON."
        case .invalidSchema(let reason):
            return "Tool schema is invalid: \(reason)"
        case .invalidArguments(let reason):
            return "Tool arguments are invalid: \(reason)"
        }
    }
}

private enum ToolSchemaValue {
    static func unwrap(_ value: Any) -> Any {
        if let wrapped = value as? AnySendable {
            return unwrap(wrapped.value)
        }
        if let dictionary = value as? [String: AnySendable] {
            return dictionary.mapValues { unwrap($0) }
        }
        if let array = value as? [AnySendable] {
            return array.map(unwrap)
        }
        return value
    }
}

private enum ToolSchemaValidator {
    static let maximumInputBytes = 1 * 1024 * 1024
    private static let maximumDepth = 64
    private static let maximumCollectionElements = 10_000

    static func validate(value: Any, schema: [String: Any], path: String, depth: Int = 0) throws {
        guard depth <= maximumDepth else {
            throw ToolValidationError.invalidArguments("\(path) exceeds the maximum nesting depth.")
        }
        try validateSizeLimits(value: value, path: path)

        if let enumValues = schema["enum"] as? [Any],
           !enumValues.contains(where: { jsonEqual(value, $0) }) {
            throw ToolValidationError.invalidArguments("\(path) is not an allowed value.")
        }

        if let type = schema["type"] as? String, !matches(value: value, type: type) {
            throw ToolValidationError.invalidArguments("\(path) must be \(type).")
        }

        if let properties = schema["properties"] as? [String: Any],
           let object = value as? [String: Any] {
            if let required = schema["required"] as? [Any] {
                for requiredValue in required {
                    guard let name = requiredValue as? String,
                          let present = object[name], !(present is NSNull) else {
                        throw ToolValidationError.invalidArguments("\(path) is missing required field \(requiredValue).")
                    }
                }
            }

            if let additionalProperties = schema["additionalProperties"] as? Bool,
               !additionalProperties,
               let unknown = object.keys.filter({ properties[$0] == nil }).sorted().first {
                throw ToolValidationError.invalidArguments("\(path).\(unknown) is not permitted.")
            }

            for (name, value) in object {
                if let propertySchema = properties[name] as? [String: Any] {
                    try validate(value: value, schema: propertySchema, path: "\(path).\(name)", depth: depth + 1)
                }
            }
        }

        if let items = value as? [Any],
           let itemSchema = schema["items"] as? [String: Any] {
            for (index, item) in items.enumerated() {
                try validate(value: item, schema: itemSchema, path: "\(path)[\(index)]", depth: depth + 1)
            }
        }
    }

    private static func matches(value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "boolean": return value is Bool
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "null": return value is NSNull
        case "number":
            return value is NSNumber && !(value is Bool)
        case "integer":
            guard let number = value as? NSNumber, !(value is Bool) else { return false }
            return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
        default:
            return false
        }
    }

    private static func validateSizeLimits(value: Any, path: String) throws {
        switch value {
        case let string as String where string.utf8.count > maximumInputBytes:
            throw ToolValidationError.invalidArguments("\(path) exceeds the maximum string size.")
        case let array as [Any] where array.count > maximumCollectionElements:
            throw ToolValidationError.invalidArguments("\(path) exceeds the maximum array size.")
        case let object as [String: Any] where object.count > maximumCollectionElements:
            throw ToolValidationError.invalidArguments("\(path) exceeds the maximum object size.")
        default:
            break
        }
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhsData = try? JSONSerialization.data(withJSONObject: [lhs], options: [.sortedKeys]),
              let rhsData = try? JSONSerialization.data(withJSONObject: [rhs], options: [.sortedKeys]) else {
            return false
        }
        return lhsData == rhsData
    }
}

/// Protocol defining a callable native Swift tool that can be invoked by an agent or LLM.
public protocol Tool: Sendable {
    var definition: ToolDefinition { get }
    var authorizationRequirement: ToolAuthorizationRequirement { get }
    func call(argumentsJSON: String) async throws -> String
}

/// Closure-based Tool implementation.
public struct ClosureTool: Tool {
    public let definition: ToolDefinition
    private let handler: @Sendable (String) async throws -> String

    public init(
        name: String,
        description: String,
        parametersSchema: [String: AnySendable] = [:],
        handler: @escaping @Sendable (String) async throws -> String
    ) {
        self.definition = ToolDefinition(name: name, description: description, parametersJSONSchema: parametersSchema)
        self.handler = handler
    }

    public func call(argumentsJSON: String) async throws -> String {
        try await handler(argumentsJSON)
    }
}
