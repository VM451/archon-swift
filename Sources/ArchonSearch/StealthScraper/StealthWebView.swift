import Foundation
import WebKit
import Vision
import ArchonCore

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Defines the scraping configuration, including custom user actions and output format.
public struct ScrapeConfiguration: Sendable, Codable, Hashable {
    public var actions: [ScrapeAction]
    public var convertToMarkdown: Bool
    public var includeSelectors: [String]
    public var excludeSelectors: [String]
    
    public init(
        actions: [ScrapeAction] = [],
        convertToMarkdown: Bool = true,
        includeSelectors: [String] = [],
        excludeSelectors: [String] = []
    ) {
        self.actions = Array(actions.prefix(32))
        self.convertToMarkdown = convertToMarkdown
        self.includeSelectors = includeSelectors
        self.excludeSelectors = excludeSelectors
    }
}

/// Supported user interaction actions to perform before content extraction.
public enum ScrapeAction: Sendable, Codable, Hashable {
    case scroll(times: Int)
    case click(selector: String)
    case waitForSelector(selector: String, timeout: TimeInterval)
    case fill(selector: String, text: String)
}

/// Bounds the strings and raster dimensions returned by a WebKit scrape.
public enum ScrapeOutputLimits: Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    /// Keep JavaScript bridge results bounded before WebKit materializes them in Swift.
    public static let maximumCharacters = maximumBytes / 4
    public static let maximumTitleBytes = 4 * 1024
    public static let maximumSnapshotWidth: CGFloat = 2048
    public static let maximumSnapshotHeight: CGFloat = 4096
}

@MainActor
public final class StealthScraper: NSObject, WKNavigationDelegate, Sendable {
    
    public struct ScrapeResult: Sendable {
        public let urlString: String
        public let html: String
        public let text: String
        public let title: String
    }
    
    private var continuation: CheckedContinuation<Void, any Error>?
    private var webView: WKWebView?
    private var navigationID: UUID?
    private let localWorkspaceRoots: [URL]
    
    public override init() {
        self.localWorkspaceRoots = []
        super.init()
    }

    public init(localWorkspaceRoots: [URL]) {
        self.localWorkspaceRoots = localWorkspaceRoots
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        super.init()
    }
    
    /// Scrapes a URL, rendering JS, running user interaction actions, and converting to structured output.
    /// Uses Vision OCR fallback for dynamic or graphical contents.
    public func scrape(url: URL, configuration: ScrapeConfiguration = ScrapeConfiguration()) async throws -> ScrapeResult {
        guard url.isFileURL ? isAllowedLocalFile(url) : SearchURLPolicy.validate(url) else {
            throw SearchError.extractionFailed(reason: "Only public HTTP(S) URLs or bounded local files are supported.")
        }
        if !url.isFileURL {
            try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "WebKit scrape")
        }
        try Task.checkCancellation()
        let config = WKWebViewConfiguration()
        
        // Inject JS to spoof human behavior
        let behaviorScript = WKUserScript(
            source: getHumanBehaviorJavaScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(behaviorScript)
        
        // Create off-screen webview
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        self.webView = webView
        webView.navigationDelegate = self
        let navigationID = UUID()
        self.navigationID = navigationID
        defer {
            self.webView = nil
            self.continuation = nil
            self.navigationID = nil
        }
        
        // Custom rotated User-Agent
        webView.customUserAgent = StealthHeaders.randomUserAgent()
        
        // Load URL
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                webView.load(URLRequest(url: url.isFileURL ? url.resolvingSymlinksInPath() : url))
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingNavigation(id: navigationID)
            }
        })
        try Task.checkCancellation()
        
        // Allow initial settle time
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        
        // Execute custom user actions sequentially
        for action in configuration.actions {
            try Task.checkCancellation()
            switch action {
            case .scroll(let times):
                for _ in 0..<min(max(times, 0), 20) {
                    try Task.checkCancellation()
                    let js = "window.scrollBy(0, window.innerHeight * 0.8);"
                    _ = try? await webView.evaluateJavaScript(js)
                    try await Task.sleep(nanoseconds: 300_000_000) // 300ms sleep
                }
            case .click(let selector):
                let selectorLiteral = Self.javascriptStringLiteral(selector)
                let js = """
                (function() {
                    let el = document.querySelector(\(selectorLiteral));
                    if (el) {
                        el.click();
                        return true;
                    }
                    return false;
                })()
                """
                try Task.checkCancellation()
                _ = try? await webView.evaluateJavaScript(js)
                try await Task.sleep(nanoseconds: 500_000_000) // Allow 500ms for UI click events
            case .fill(let selector, let text):
                let selectorLiteral = Self.javascriptStringLiteral(selector)
                let textLiteral = Self.javascriptStringLiteral(text)
                let js = """
                (function() {
                    let el = document.querySelector(\(selectorLiteral));
                    if (el) {
                        el.value = \(textLiteral);
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        return true;
                    }
                    return false;
                })()
                """
                try Task.checkCancellation()
                _ = try? await webView.evaluateJavaScript(js)
            case .waitForSelector(let selector, let timeout):
                let selectorLiteral = Self.javascriptStringLiteral(selector)
                let startTime = Date()
                while Date().timeIntervalSince(startTime) < min(max(timeout, 0), 30) {
                    try Task.checkCancellation()
                    let checkJS = "document.querySelector(\(selectorLiteral)) !== null"
                    if let exists = try? await webView.evaluateJavaScript(checkJS) as? Bool, exists {
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms interval
                }
            }
        }
        
        // Extract standard text and HTML
        try Task.checkCancellation()
        let html = Self.boundedOutput(
            try await webView.evaluateJavaScript(
                "document.documentElement.outerHTML.slice(0, \(ScrapeOutputLimits.maximumCharacters))"
            ) as? String ?? ""
        )
        let title = Self.boundedOutput(
            try await webView.evaluateJavaScript(
                "document.title.slice(0, \(ScrapeOutputLimits.maximumTitleBytes))"
            ) as? String ?? "",
            maximumBytes: ScrapeOutputLimits.maximumTitleBytes
        )
        
        // Extract text based on markdown setting
        var bodyText = ""
        if configuration.convertToMarkdown {
            let markdownScript = getDOMToMarkdownJavaScript(
                include: configuration.includeSelectors,
                exclude: configuration.excludeSelectors
            )
            bodyText = Self.boundedOutput(try await webView.evaluateJavaScript(markdownScript) as? String ?? "")
        } else {
            bodyText = Self.boundedOutput(
                try await webView.evaluateJavaScript(
                    "document.body.innerText.slice(0, \(ScrapeOutputLimits.maximumCharacters))"
                ) as? String ?? ""
            )
        }
        try Task.checkCancellation()
        
        // Try OCR fallback
        var finalocrText = ""
        do {
            // Apply visual display hiding before taking the snapshot to align OCR with whitelists/blacklists
            if !configuration.excludeSelectors.isEmpty || !configuration.includeSelectors.isEmpty {
                let excludeJSON = (try? String(data: JSONSerialization.data(withJSONObject: configuration.excludeSelectors), encoding: .utf8)) ?? "[]"
                let includeJSON = (try? String(data: JSONSerialization.data(withJSONObject: configuration.includeSelectors), encoding: .utf8)) ?? "[]"
                
                let hideJS = """
                (function() {
                    let excludes = \(excludeJSON);
                    excludes.forEach(sel => {
                        document.querySelectorAll(sel).forEach(e => {
                            e.style.display = 'none';
                        });
                    });
                    
                    let includes = \(includeJSON);
                    if (includes.length > 0) {
                        document.body.querySelectorAll('*').forEach(e => {
                            let isInside = includes.some(sel => e.closest(sel) !== null);
                            let containsSome = includes.some(sel => e.querySelector(sel) !== null);
                            if (!isInside && !containsSome) {
                                e.style.display = 'none';
                            }
                        });
                    }
                })()
                """
                _ = try? await webView.evaluateJavaScript(hideJS)
            }
            
            let snapshot = try await captureSnapshot(of: webView)
            finalocrText = Self.boundedOutput(try await runOCR(on: snapshot))
        } catch {
            // Ignore snapshot/OCR errors and fallback to bodyText
        }
        
        let mergedText = Self.boundedOutput(
            bodyText + (finalocrText.isEmpty ? "" : "\n\n[Visual OCR Content]:\n" + finalocrText)
        )
        
        // Clean references
        self.webView = nil
        self.continuation = nil
        
        return ScrapeResult(urlString: url.absoluteString, html: html, text: mergedText, title: title)
    }

    private func isAllowedLocalFile(_ url: URL) -> Bool {
        guard SearchURLPolicy.validateLocalFile(url), !localWorkspaceRoots.isEmpty else { return false }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return localWorkspaceRoots.contains { root in
            let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
            return resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/")
        }
    }
    
    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              SearchURLPolicy.validateRemoteOrLocalFile(url),
              url.isFileURL || !ArchonNetworkSecurity.isZeroCloudEnabled else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
        navigationID = nil
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        navigationID = nil
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        navigationID = nil
    }

    private func cancelPendingNavigation(id: UUID) {
        guard navigationID == id else { return }
        webView?.stopLoading()
        let pendingContinuation = continuation
        continuation = nil
        navigationID = nil
        pendingContinuation?.resume(throwing: CancellationError())
    }
    
    // MARK: - OCR & Snapshot Helpers
    
    private func captureSnapshot(of webView: WKWebView) async throws -> PlatformImage {
        return try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(
                x: 0,
                y: 0,
                width: ScrapeOutputLimits.maximumSnapshotWidth,
                height: ScrapeOutputLimits.maximumSnapshotHeight
            )
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
        }
    }
    
    private func runOCR(on image: PlatformImage) async throws -> String {
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        #else
        guard let cgImage = image.cgImage else {
            return ""
        }
        #endif
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try requestHandler.perform([request])
                guard let results = request.results else {
                    continuation.resume(returning: "")
                    return
                }
                
                let lines = results.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: Self.boundedJoinedLines(lines))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func boundedOutput(
        _ output: String,
        maximumBytes: Int = ScrapeOutputLimits.maximumBytes
    ) -> String {
        guard output.utf8.count > maximumBytes else { return output }
        let marker = "\n[output truncated]"
        let prefixLimit = max(0, maximumBytes - marker.utf8.count)
        let prefix = output.utf8.prefix(prefixLimit)
        return String(decoding: prefix, as: UTF8.self) + marker
    }

    private static func boundedJoinedLines(_ lines: [String]) -> String {
        let marker = "\n[output truncated]"
        let contentLimit = max(0, ScrapeOutputLimits.maximumBytes - marker.utf8.count)
        var output = Data()
        output.reserveCapacity(min(contentLimit, 64 * 1024))
        var truncated = false
        for line in lines {
            let separator = output.isEmpty ? Data() : Data([10])
            let remaining = contentLimit - output.count - separator.count
            guard remaining > 0 else {
                truncated = true
                break
            }

            let lineData = Data(line.utf8)
            output.append(separator)
            if lineData.count <= remaining {
                output.append(lineData)
            } else {
                output.append(lineData.prefix(remaining))
                truncated = true
                break
            }
        }
        let result = String(decoding: output, as: UTF8.self)
        return truncated ? result + marker : result
    }
    
    // MARK: - JavaScript Generation
    
    private func getHumanBehaviorJavaScript() -> String {
        return """
        (function() {
            function scrollRandomly() {
                let maxScroll = document.body.scrollHeight - window.innerHeight;
                if (maxScroll <= 0) return;
                let target = Math.random() * maxScroll;
                let current = window.scrollY;
                let step = (target - current) / 20;
                let count = 0;
                let timer = setInterval(() => {
                    window.scrollBy(0, step + (Math.random() - 0.5) * 5);
                    count++;
                    if (count >= 20) {
                        clearInterval(timer);
                    }
                }, 50);
            }
            setInterval(scrollRandomly, 5000);
            
            function dispatchFakeMove() {
                let evt = new MouseEvent("mousemove", {
                    view: window,
                    bubbles: true,
                    cancelable: true,
                    clientX: Math.random() * window.innerWidth,
                    clientY: Math.random() * window.innerHeight
                });
                document.dispatchEvent(evt);
            }
            setInterval(dispatchFakeMove, 2000);
            
            try {
                Object.defineProperty(navigator, 'webdriver', {
                    get: () => undefined
                });
            } catch (e) {}
        })();
        """
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
    }
    
    private func getDOMToMarkdownJavaScript(include: [String], exclude: [String]) -> String {
        let includeJSON = (try? String(data: JSONSerialization.data(withJSONObject: include), encoding: .utf8)) ?? "[]"
        let excludeJSON = (try? String(data: JSONSerialization.data(withJSONObject: exclude), encoding: .utf8)) ?? "[]"
        
        return """
        (function() {
            let body = document.body.cloneNode(true);
            
            let excludes = \(excludeJSON);
            excludes.forEach(sel => {
                if (body.matches && body.matches(sel)) {
                    body.innerHTML = '';
                } else {
                    let elms = body.querySelectorAll(sel);
                    elms.forEach(e => e.remove());
                }
            });
            
            let elementsToRemove = body.querySelectorAll('script, style, head, nav, header, footer, form, iframe, noscript, svg, path, img, canvas');
            elementsToRemove.forEach(el => el.remove());
            
            let includes = \(includeJSON);
            let targetNode = body;
            if (includes.length > 0) {
                let tempContainer = document.createElement('div');
                includes.forEach(sel => {
                    let elms = body.querySelectorAll(sel);
                    elms.forEach(e => {
                        tempContainer.appendChild(e.cloneNode(true));
                    });
                });
                if (tempContainer.childNodes.length > 0) {
                    targetNode = tempContainer;
                }
            }
            
            let markdown = "";

            const maximumOutputCharacters = \(ScrapeOutputLimits.maximumCharacters);
            function append(value) {
                if (markdown.length >= maximumOutputCharacters) return;
                markdown += String(value).slice(0, maximumOutputCharacters - markdown.length);
            }
            
            function walk(node) {
                if (node.nodeType === 3) { // TEXT_NODE
                    let text = node.nodeValue.trim();
                    if (text) {
                        append(text + " ");
                    }
                    return;
                }
                
                if (node.nodeType === 1) { // ELEMENT_NODE
                    let tagName = node.tagName.toLowerCase();
                    
                    if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].includes(tagName)) {
                        append("\\n\\n" + "#".repeat(parseInt(tagName[1])) + " ");
                        node.childNodes.forEach(walk);
                        append("\\n\\n");
                        return;
                    }
                    
                    if (tagName === 'p') {
                        append("\\n\\n");
                        node.childNodes.forEach(walk);
                        append("\\n\\n");
                        return;
                    }
                    
                    if (tagName === 'a') {
                        let href = node.getAttribute('href') || "";
                        if (href.startsWith('http')) {
                            append(" [");
                            node.childNodes.forEach(walk);
                            append("](" + href + ") ");
                        } else {
                            node.childNodes.forEach(walk);
                        }
                        return;
                    }
                    
                    if (tagName === 'li') {
                        append("\\n* ");
                        node.childNodes.forEach(walk);
                        return;
                    }
                    
                    if (tagName === 'tr') {
                        append("\\n| ");
                        node.childNodes.forEach(walk);
                        append(" |");
                        return;
                    }
                    
                    if (tagName === 'td' || tagName === 'th') {
                        node.childNodes.forEach(walk);
                        append(" | ");
                        return;
                    }
                    
                    node.childNodes.forEach(walk);
                }
            }
            
            walk(targetNode);
            return markdown
                .replace(/\\n\\s*\\n/g, '\\n\\n')
                .replace(/[ \\t]+/g, ' ')
                .trim()
                .slice(0, maximumOutputCharacters);
        })()
        """
    }
}
