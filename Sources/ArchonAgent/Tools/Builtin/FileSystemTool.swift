import Foundation

/// Safe, sandboxed on-device file system tool for reading, writing, and listing files.
public struct FileSystemTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "fileSystem",
            description: "Performs sandboxed file operations such as reading, writing, or listing files.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action to perform: 'read', 'write', or 'list'")
                    ]),
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Target file path relative to sandbox")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Content to write (optional for write action)")
                    ])
                ]),
                "required": AnySendable([AnySendable("action"), AnySendable("path")])
            ]
        )
    }

    private let rootDirectory: URL

    public init(rootDirectory: URL = FileManager.default.temporaryDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String,
              let path = json["path"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "fileSystem", errorDescription: "Invalid parameters.")
        }

        let targetURL = try SandboxPathResolver.resolve(path, relativeTo: rootDirectory)

        switch action.lowercased() {
        case "read":
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                return "Error: File not found at '\(path)'."
            }
            let text = try String(contentsOf: targetURL, encoding: .utf8)
            return text

        case "write":
            let content = json["content"] as? String ?? ""
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
            return "Successfully written \(content.count) bytes to '\(path)'."

        case "list":
            let items = try FileManager.default.contentsOfDirectory(atPath: targetURL.path)
            return items.joined(separator: "\n")

        default:
            return "Error: Unsupported action '\(action)'."
        }
    }
}

/// Offline-friendly web search and documentation lookup tool.
public struct WebSearchTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "webSearch",
            description: "Searches documentation and knowledge sources for queries.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Search query term")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    }

    private let searchHandler: @Sendable (String) async throws -> String

    public init() {
        self.searchHandler = { _ in
            throw GraphError.toolExecutionFailed(
                toolName: "webSearch",
                errorDescription: "No web search provider has been configured."
            )
        }
    }

    /// Creates a production adapter backed by the host's configured search
    /// service, such as `ArchonSearch`. The Agent module stays independent of
    /// any concrete search implementation.
    public init(searchHandler: @escaping @Sendable (String) async throws -> String) {
        self.searchHandler = searchHandler
    }

    /// Creates a deterministic test double. A missing query is an error rather
    /// than a fabricated search hit.
    public init(mockResults: [String: String]) {
        self.searchHandler = { query in
            if let exact = mockResults[query] {
                return exact
            }
            throw GraphError.toolExecutionFailed(
                toolName: "webSearch",
                errorDescription: "No mock result is registered for '\(query)'."
            )
        }
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "webSearch", errorDescription: "Missing query.")
        }

        return try await searchHandler(query)
    }
}

/// Native Apple device info tool providing telemetry, OS version, RAM, and thermal state.
public struct DeviceInfoTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "deviceInfo",
            description: "Fetches Apple platform hardware specifications, OS version, memory, and thermal state.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([String: AnySendable]()),
                "required": AnySendable([AnySendable]())
            ]
        )
    }

    public init() {}

    public func call(argumentsJSON: String) async throws -> String {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let memoryGB = Double(processInfo.physicalMemory) / 1_073_741_824.0
        let thermal = processInfo.thermalState

        let thermalString: String
        switch thermal {
        case .nominal: thermalString = "Nominal"
        case .fair: thermalString = "Fair"
        case .serious: thermalString = "Serious"
        case .critical: thermalString = "Critical"
        @unknown default: thermalString = "Unknown"
        }

        return """
        OS Version: \(osVersion)
        Physical Memory: \(String(format: "%.2f", memoryGB)) GB
        Thermal State: \(thermalString)
        Processor Count: \(processInfo.activeProcessorCount)
        """
    }
}
