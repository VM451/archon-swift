import Foundation
#if canImport(WebKit)
import WebKit

/// Thread-safe URL scheme handler intercepting `sandbox://` requests to serve virtual files in-memory without accessing local filesystem.
public final class SandboxURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    public static let scheme = "sandbox"
    public static let host = "app"
    
    private let lock = NSLock()
    private var workspaceProvider: @Sendable () -> SandboxWorkspace
    private let configuration: SandboxConfiguration
    private var activeTasks: Set<ObjectIdentifier> = []
    
    public init(
        workspaceProvider: @escaping @Sendable () -> SandboxWorkspace,
        configuration: SandboxConfiguration = .default
    ) {
        self.workspaceProvider = workspaceProvider
        self.configuration = configuration
        super.init()
    }
    
    public func updateWorkspaceProvider(_ provider: @escaping @Sendable () -> SandboxWorkspace) {
        lock.lock()
        defer { lock.unlock() }
        self.workspaceProvider = provider
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.insert(taskID)
        let currentWorkspace = workspaceProvider()
        lock.unlock()
        
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "SandboxURLSchemeHandler", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Request URL"]))
            return
        }
        
        // Extract relative path from sandbox://app/index.html or sandbox://index.html
        var path = url.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        if path.isEmpty {
            path = currentWorkspace.entryPointPath
        }
        
        // Check for virtual file in workspace
        guard let file = currentWorkspace.file(at: path) else {
            let notFoundHTML = """
            <!DOCTYPE html>
            <html>
            <head><title>404 Not Found</title></head>
            <body style="font-family: -apple-system; padding: 20px; text-align: center;">
                <h2>404 Not Found</h2>
                <p>Virtual file <code>\(path)</code> not found in SandboxWorkspace.</p>
            </body>
            </html>
            """
            let notFoundData = Data(notFoundHTML.utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(notFoundData.count)",
                    "Cache-Control": "no-cache, no-store, must-revalidate",
                    "X-Content-Type-Options": "nosniff"
                ]
            )!
            
            lock.lock()
            let isActive = activeTasks.contains(taskID)
            lock.unlock()
            
            if isActive {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(notFoundData)
                urlSchemeTask.didFinish()
                lock.lock()
                activeTasks.remove(taskID)
                lock.unlock()
            }
            return
        }
        
        let data: Data
        if file.mimeType.lowercased().hasPrefix("text/html"),
           let html = file.content.utf8Text {
            data = Data(SandboxCSPBuilder.injectCSP(into: html, configuration: configuration).utf8)
        } else {
            data = file.content.rawData
        }
        let headers: [String: String] = [
            "Content-Type": file.mimeType,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "X-Content-Type-Options": "nosniff",
            "ETag": "\"\(file.checksum)\""
        ]
        
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        
        lock.lock()
        let isActive = activeTasks.contains(taskID)
        lock.unlock()
        
        if isActive {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            lock.lock()
            activeTasks.remove(taskID)
            lock.unlock()
        }
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.remove(taskID)
        lock.unlock()
    }
}
#endif
