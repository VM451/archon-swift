import Foundation

/// Represents the snapshot state and virtual file tree of a Sandboxed mini web application.
public struct SandboxWorkspace: Identifiable, Sendable, Codable, Hashable, Equatable {
    public let id: UUID
    public var name: String
    public var files: [SandboxFile]
    public var entryPointPath: String
    public var metadata: [String: String]
    public var createdAt: Date
    public var lastModified: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        files: [SandboxFile] = [],
        entryPointPath: String = "index.html",
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.files = files
        self.entryPointPath = entryPointPath
        self.metadata = metadata
        self.createdAt = createdAt
        self.lastModified = lastModified
    }
    
    /// Total virtual storage consumption in bytes.
    public var totalSizeInBytes: Int {
        files.reduce(0) { $0 + $1.sizeInBytes }
    }
    
    /// Creates a workspace from a map of relative file paths to text or binary content.
    public init(name: String, fileMap: [String: String], entryPointPath: String = "index.html") {
        let files = fileMap.map { (path, text) in
            SandboxFile(path: path, text: text)
        }
        self.init(name: name, files: files, entryPointPath: entryPointPath)
    }
    
    /// Creates a workspace from raw binary data files.
    public init(name: String, binaryFiles: [String: Data], entryPointPath: String = "index.html") {
        let files = binaryFiles.map { (path, data) in
            SandboxFile(path: path, data: data)
        }
        self.init(name: name, files: files, entryPointPath: entryPointPath)
    }
    
    /// Exports all virtual files as a path-to-content dictionary.
    public func exportFileMap() -> [String: String] {
        var map: [String: String] = [:]
        for file in files {
            if let text = file.content.utf8Text {
                map[file.path] = text
            }
        }
        return map
    }
    
    /// Returns a specific file given its relative path.
    public func file(at path: String) -> SandboxFile? {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return files.first(where: { $0.path == normalizedPath })
    }
    
    /// Adds or updates a file in the workspace, updating the workspace timestamp.
    public mutating func upsertFile(_ file: SandboxFile) {
        if let index = files.firstIndex(where: { $0.path == file.path }) {
            files[index] = file
        } else {
            files.append(file)
        }
        self.lastModified = Date()
    }
    
    /// Removes a file by path from the workspace.
    @discardableResult
    public mutating func removeFile(at path: String) -> SandboxFile? {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let index = files.firstIndex(where: { $0.path == normalizedPath }) {
            let removed = files.remove(at: index)
            self.lastModified = Date()
            return removed
        }
        return nil
    }
    
    /// Returns the entry point file (usually index.html).
    public var entryPointFile: SandboxFile? {
        self.file(at: entryPointPath)
    }
    
    /// Creates a default starter workspace with minimal HTML5 canvas/app structure.
    public static func defaultTemplate(name: String = "Interactive Sandbox") -> SandboxWorkspace {
        let defaultHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(name)</title>
            <style>
                :root {
                    color-scheme: light dark;
                    --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    --bg-color: #f5f5f7;
                    --card-bg: #ffffff;
                    --text-primary: #1d1d1f;
                    --accent-color: #0071e3;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --bg-color: #000000;
                        --card-bg: #1c1c1e;
                        --text-primary: #f5f5f7;
                        --accent-color: #2997ff;
                    }
                }
                body {
                    margin: 0;
                    padding: 24px;
                    font-family: var(--font-family);
                    background-color: var(--bg-color);
                    color: var(--text-primary);
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                    box-sizing: border-box;
                }
                .card {
                    background: var(--card-bg);
                    border-radius: 16px;
                    padding: 32px;
                    box-shadow: 0 4px 20px rgba(0,0,0,0.08);
                    max-width: 480px;
                    width: 100%;
                    text-align: center;
                }
                h1 {
                    font-size: 24px;
                    margin-top: 0;
                    margin-bottom: 12px;
                }
                p {
                    font-size: 15px;
                    line-height: 1.5;
                    opacity: 0.8;
                    margin-bottom: 24px;
                }
                button {
                    background-color: var(--accent-color);
                    color: white;
                    border: none;
                    padding: 12px 24px;
                    border-radius: 980px;
                    font-size: 15px;
                    font-weight: 500;
                    cursor: pointer;
                    transition: transform 0.1s ease, opacity 0.2s ease;
                }
                button:active {
                    transform: scale(0.97);
                }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>\(name)</h1>
                <p>Rendered securely inside ArchonSandbox with zero external server dependencies.</p>
                <button id="actionBtn" onclick="handleNativeBridgeAction()">Invoke AI Agent Tool</button>
            </div>
            <script>
                function handleNativeBridgeAction() {
                    console.log("[JS Bridge] Button tapped, invoking native Agent tool...");
                    if (window.SwiftSandboxBridge) {
                        window.SwiftSandboxBridge.postMessage({
                            id: crypto.randomUUID ? crypto.randomUUID() : 'req-' + Date.now(),
                            type: 'TOOL_CALL',
                            payload: {
                                toolName: 'SampleTool',
                                arguments: { action: 'ping', timestamp: Date.now() }
                            },
                            timestamp: Date.now()
                        });
                    }
                }
            </script>
        </body>
        </html>
        """
        
        let indexFile = SandboxFile(path: "index.html", text: defaultHTML, mimeType: "text/html; charset=utf-8")
        return SandboxWorkspace(name: name, files: [indexFile], entryPointPath: "index.html")
    }
}
