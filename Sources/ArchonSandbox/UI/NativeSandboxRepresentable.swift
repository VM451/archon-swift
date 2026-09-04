import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

#if os(iOS)
#if canImport(WebKit)
public struct NativeSandboxRepresentable: UIViewRepresentable {
    @ObservedObject var controller: SandboxViewController
    
    public init(controller: SandboxViewController) {
        self.controller = controller
    }
    
    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let workspace = controller.workspace
        let schemeHandler = SandboxURLSchemeHandler(
            workspaceProvider: { workspace },
            configuration: controller.configuration
        )
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: SandboxURLSchemeHandler.scheme)
        
        let contentController = WKUserContentController()
        let scriptSource = SandboxScriptBridge.generateBootstrapScript()
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        contentController.add(context.coordinator, name: SandboxScriptBridge.handlerName)
        configuration.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.isInspectable = controller.configuration.isInspectable
        
        controller.webView = webView
        
        // Bind engine JS evaluator
        let engine = controller.engine
        Task { [weak webView] in
            await engine.bindEvaluator { script in
                guard let webView = webView else {
                    throw SandboxError.engineDeallocated
                }
                let result = try await webView.evaluateJavaScript(script)
                if let str = result as? String {
                    return str
                } else if let result = result {
                    return String(describing: result)
                }
                return ""
            }
        }
        
        // Load initial entry point
        if let url = URL(string: "sandbox://app/\(controller.workspace.entryPointPath)") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }
    
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let controller: SandboxViewController
        
        init(controller: SandboxViewController) {
            self.controller = controller
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol.lowercased() == SandboxURLSchemeHandler.scheme,
                  message.frameInfo.securityOrigin.host.lowercased() == SandboxURLSchemeHandler.host else { return }
            if let dict = message.body as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: data, encoding: .utf8) {
                let engine = controller.engine
                Task {
                    await engine.handleIncomingJSON(jsonString)
                }
            }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(isAllowed(navigationAction.request.url) ? .allow : .cancel)
        }

        private func isAllowed(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased() else { return false }
            let configuration = controller.configuration
            guard configuration.allowedSchemes.map({ $0.lowercased() }).contains(scheme) else { return false }
            if (scheme == "http" || scheme == "https") && !configuration.allowNetworkAccess { return false }
            return scheme != SandboxURLSchemeHandler.scheme || url.host?.lowercased() == SandboxURLSchemeHandler.host
        }
    }
}
#endif

#elseif os(macOS)
#if canImport(WebKit)
public struct NativeSandboxRepresentable: NSViewRepresentable {
    @ObservedObject var controller: SandboxViewController
    
    public init(controller: SandboxViewController) {
        self.controller = controller
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let workspace = controller.workspace
        let schemeHandler = SandboxURLSchemeHandler(
            workspaceProvider: { workspace },
            configuration: controller.configuration
        )
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: SandboxURLSchemeHandler.scheme)
        
        let contentController = WKUserContentController()
        let scriptSource = SandboxScriptBridge.generateBootstrapScript()
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        contentController.add(context.coordinator, name: SandboxScriptBridge.handlerName)
        configuration.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = controller.configuration.isInspectable
        
        controller.webView = webView
        
        // Bind engine JS evaluator
        let engine = controller.engine
        Task { [weak webView] in
            await engine.bindEvaluator { script in
                guard let webView = webView else {
                    throw SandboxError.engineDeallocated
                }
                let result = try await webView.evaluateJavaScript(script)
                if let str = result as? String {
                    return str
                } else if let result = result {
                    return String(describing: result)
                }
                return ""
            }
        }
        
        // Load initial entry point
        if let url = URL(string: "sandbox://app/\(controller.workspace.entryPointPath)") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }
    
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let controller: SandboxViewController
        
        init(controller: SandboxViewController) {
            self.controller = controller
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol.lowercased() == SandboxURLSchemeHandler.scheme,
                  message.frameInfo.securityOrigin.host.lowercased() == SandboxURLSchemeHandler.host else { return }
            if let dict = message.body as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: data, encoding: .utf8) {
                let engine = controller.engine
                Task {
                    await engine.handleIncomingJSON(jsonString)
                }
            }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(isAllowed(navigationAction.request.url) ? .allow : .cancel)
        }

        private func isAllowed(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased() else { return false }
            let configuration = controller.configuration
            guard configuration.allowedSchemes.map({ $0.lowercased() }).contains(scheme) else { return false }
            if (scheme == "http" || scheme == "https") && !configuration.allowNetworkAccess { return false }
            return scheme != SandboxURLSchemeHandler.scheme || url.host?.lowercased() == SandboxURLSchemeHandler.host
        }
    }
}
#endif
#endif
