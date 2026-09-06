import Foundation

/// Defines standard OpenAPI / JSON Schema tool definitions and execution handlers for integrating
/// ArchonSandbox with ArchonAgent and native Apple Foundation Model tool dispatchers.
public struct ArchonSandboxAgentTools: Sendable {

    /// Returns the complete OpenAPI / JSON Schema definitions for all sandbox capabilities as a JSON string.
    public static func toolsJSONSchemaString() -> String {
        """
        [
          {
            "name": "sandbox_render_web_app",
            "description": "Renders or replaces the active HTML5/JS/CSS web application in the embedded client sandbox.",
            "parameters": {
              "type": "object",
              "properties": {
                "html": { "type": "string", "description": "Complete HTML document structure to render" }
              },
              "required": ["html"]
            }
          },
          {
            "name": "sandbox_patch_dom",
            "description": "Applies live JavaScript execution deltas and CSS stylesheet patches to the running sandbox web app.",
            "parameters": {
              "type": "object",
              "properties": {
                "jsDelta": { "type": "string", "description": "JavaScript snippet to execute in sandbox context" },
                "cssDelta": { "type": "string", "description": "Optional CSS rules to inject into sandbox document head" }
              },
              "required": ["jsDelta"]
            }
          },
          {
            "name": "sandbox_inspect_dom",
            "description": "Extracts a token-optimized semantic Markdown or JSON representation of the live sandbox DOM.",
            "parameters": {
              "type": "object",
              "properties": {
                "format": { "type": "string", "description": "Format to return: 'markdown' or 'json' (default: 'markdown')" },
                "maxTokens": { "type": "integer", "description": "Token budget for pruning the DOM hierarchy (default: 4096, maximum: 64000)" }
              }
            }
          },
          {
            "name": "sandbox_write_file",
            "description": "Writes or updates a virtual file in the sandbox workspace without disk leakage.",
            "parameters": {
              "type": "object",
              "properties": {
                "path": { "type": "string", "description": "Relative file path (e.g., 'app.js', 'styles.css')" },
                "content": { "type": "string", "description": "UTF-8 text content to write" }
              },
              "required": ["path", "content"]
            }
          },
          {
            "name": "sandbox_read_file",
            "description": "Reads a virtual file from the sandbox workspace.",
            "parameters": {
              "type": "object",
              "properties": {
                "path": { "type": "string", "description": "Relative file path to read" }
              },
              "required": ["path"]
            }
          },
          {
            "name": "sandbox_list_files",
            "description": "Lists all virtual files in the sandbox workspace.",
            "parameters": {
              "type": "object",
              "properties": {}
            }
          }
        ]
        """
    }

    /// Handles tool execution against a live workspace.
    public static func handleToolCall(
        workspace: inout SandboxWorkspace,
        toolName: String,
        argumentsJSON: String
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Error: Invalid JSON arguments for tool '\(toolName)'."
        }

        switch toolName {
        case "sandbox_render_web_app":
            guard let html = json["html"] as? String else {
                return "Error: Missing 'html' parameter."
            }
            guard html.utf8.count <= 8 * 1024 * 1024 else { return "Error: HTML exceeds the 8 MB sandbox limit." }
            let indexFile = SandboxFile(path: "index.html", text: html)
            workspace.upsertFile(indexFile)
            workspace.lastModified = Date()
            return "Successfully rendered web app in workspace '\(workspace.name)' (\(html.count) bytes)."

        case "sandbox_patch_dom":
            guard let jsDelta = json["jsDelta"] as? String else {
                return "Error: Missing 'jsDelta' parameter."
            }
            let cssDelta = json["cssDelta"] as? String
            return "Sandbox patch staged: JS (\(jsDelta.count) bytes), CSS (\(cssDelta?.count ?? 0) bytes)."

        case "sandbox_inspect_dom":
            let maxTokens = (json["maxTokens"] as? Int) ?? 4096
            guard (0...SemanticDOMExtractor.maximumTokenBudget).contains(maxTokens) else {
                return "Error: maxTokens must be between 0 and \(SemanticDOMExtractor.maximumTokenBudget)."
            }
            if let indexFile = workspace.file(at: "index.html"), let text = indexFile.content.utf8Text {
                let markdown = SemanticDOMExtractor.jsonToSemanticMarkdown(text)
                return SemanticDOMExtractor.pruneToTokenBudget(markdown, maxTokens: maxTokens)
            }
            return "# Empty Sandbox DOM\n- Workspace has no loaded index.html."

        case "sandbox_write_file":
            guard let path = json["path"] as? String,
                  let content = json["content"] as? String else {
                return "Error: Missing 'path' or 'content' parameter."
            }
            guard content.utf8.count <= 8 * 1024 * 1024,
                  !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                return "Error: Invalid or oversized sandbox file."
            }
            let file = SandboxFile(path: path, text: content)
            workspace.upsertFile(file)
            workspace.lastModified = Date()
            return "Successfully wrote file '\(path)' (\(content.count) bytes) to workspace."

        case "sandbox_read_file":
            guard let path = json["path"] as? String else {
                return "Error: Missing 'path' parameter."
            }
            guard let file = workspace.file(at: path), let text = file.content.utf8Text else {
                return "Error: File '\(path)' not found in workspace."
            }
            return text

        case "sandbox_list_files":
            let list = workspace.files.map { "\($0.path) (\($0.sizeInBytes) bytes)" }
            return list.isEmpty ? "Workspace is empty." : list.joined(separator: "\n")

        default:
            return "Error: Unsupported tool '\(toolName)'."
        }
    }
}
