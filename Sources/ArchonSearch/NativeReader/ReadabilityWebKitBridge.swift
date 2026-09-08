import Foundation
import WebKit
import ArchonCore

/// In-process WebKit runner that executes a Readability extraction script on JS-heavy pages.
@MainActor
public final class ReadabilityWebKitBridge: NSObject, WKNavigationDelegate, Sendable {
    private struct JSResult: Codable {
        let title: String?
        let author: String?
        let publishedAt: String?
        let headings: [String]?
        let text: String?
        let html: String?
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var webView: WKWebView?

    public func extract(url: URL, timeout: TimeInterval = 15.0) async throws -> ExtractedArticle {
        guard SearchURLPolicy.validate(url) else {
            throw SearchError.invalidURL(urlString: url.absoluteString)
        }
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "ReadabilityWebKitBridge")
        try Task.checkCancellation()

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        self.webView = wv
        wv.navigationDelegate = self
        wv.customUserAgent = StealthHeaders.randomUserAgent()
        defer { self.webView = nil; self.continuation = nil }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                wv.load(URLRequest(url: url))
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.continuation?.resume(throwing: CancellationError())
                self?.continuation = nil
            }
        })

        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s settle time

        guard let rawJSON = try await wv.evaluateJavaScript(Self.readabilityScript) as? String,
              let data = rawJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(JSResult.self, from: data) else {
            throw SearchError.extractionFailed(reason: "Readability script produced no readable content.")
        }

        let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SearchError.extractionFailed(reason: "Extracted article body is empty.")
        }

        let title = (result.title?.isEmpty == false ? result.title : nil) ?? HTMLContentExtractor.extractTitle(from: result.html ?? "")
        let author = result.author?.isEmpty == false ? result.author : nil
        let publishedAt = result.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let md = SwiftSoupArticleExtractor().extract(html: result.html ?? "", url: url)?.markdown ?? text

        return ExtractedArticle(
            title: title,
            author: author,
            publishedAt: publishedAt,
            headings: result.headings ?? [],
            text: text,
            markdown: md
        )
    }

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    private static let readabilityScript = """
    (function() {
        var drop = document.querySelectorAll('script, style, noscript, nav, header, footer, aside, iframe, svg, form, [aria-modal="true"], .ad, .ads, .banner, .cookie, .consent, .modal');
        for (var i = 0; i < drop.length; i++) drop[i].remove();
        var title = document.title || '';
        var author = '';
        var metaAuthor = document.querySelector('meta[name="author"], meta[property="article:author"]');
        if (metaAuthor) author = metaAuthor.getAttribute('content') || '';
        var pubDate = '';
        var metaTime = document.querySelector('meta[property="article:published_time"], time[datetime]');
        if (metaTime) pubDate = metaTime.getAttribute('content') || metaTime.getAttribute('datetime') || '';
        var headings = [];
        var hTags = document.querySelectorAll('h1, h2, h3');
        for (var i = 0; i < Math.min(hTags.length, 16); i++) {
            var ht = hTags[i].innerText ? hTags[i].innerText.trim() : '';
            if (ht.length > 0) headings.push(ht);
        }
        var target = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]') || document.body;
        if (!target) return null;
        var text = (target.innerText || '').trim();
        var html = target.innerHTML || '';
        return JSON.stringify({
            title: title,
            author: author,
            publishedAt: pubDate,
            headings: headings,
            text: text,
            html: html.substring(0, 100000)
        });
    })()
    """
}
