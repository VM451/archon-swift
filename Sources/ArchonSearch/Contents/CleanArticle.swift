import Foundation

/// How a ``CleanArticle`` was produced.
public enum ArticleExtractionMethod: String, Sendable, Codable, Hashable {
    /// Static `URLSession` fetch plus in-process article extraction.
    case staticFetch
    /// Static fetch yielded too little content, so the page was re-rendered
    /// in `WKWebView` (`StealthScraper`) before extraction.
    case escalatedRender
}

/// Article-ready page content for model context windows.
///
/// `CleanArticle` is the boundary between page retrieval and model
/// consumption: it carries the readable title, author, and body text without
/// navigation chrome, ads, cookie banners, or comment/footer boilerplate, so
/// Foundation Models never spend context on raw HTML.
public struct CleanArticle: Sendable, Codable, Hashable {
    public let url: URL
    public let title: String
    public let author: String?
    public let publishedAt: Date?
    public let text: String
    public let headings: [String]
    public let method: ArticleExtractionMethod

    public init(
        url: URL,
        title: String,
        author: String? = nil,
        publishedAt: Date? = nil,
        text: String,
        headings: [String] = [],
        method: ArticleExtractionMethod
    ) {
        self.url = url
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.text = text
        self.headings = Array(headings.prefix(32))
        self.method = method
    }

    /// Below this body length the page is treated as a JS shell or a failed
    /// extraction and becomes eligible for rendered-fallback escalation.
    public static let minimumBodyCharacters = 400
}

/// Vendor-neutral article-extraction seam.
///
/// The bundled ``HeuristicArticleExtractor`` is the dependency-free default.
/// A future SwiftSoup or Mozilla-Readability adapter conforms here without
/// changing call sites; see `Documentation/explanation/extraction-pipeline.md`.
public protocol ArticleExtractor: Sendable {
    func extractArticle(from html: String, url: URL) -> CleanArticle?
}

/// Dependency-free Readability-style article extractor.
///
/// Strategy, mirroring the Mozilla Readability algorithm at a deliberately
/// smaller scope:
/// 1. Drop `script`/`style`/`noscript`/`template` subtrees.
/// 2. Drop boilerplate containers (`nav`, `header`, `footer`, `aside`,
///    `form`, ad/comment/cookie/promo blocks matched by `id`/`class`).
/// 3. Prefer `<article>`/`<main>` subtrees when present.
/// 4. Score remaining block-level containers by paragraph density and pick
///    the best candidate as the article body.
/// 5. Read title, `meta[name=author]`, headings, and `time[datetime]`/
///    `meta[property=article:published_time]` metadata.
public struct HeuristicArticleExtractor: ArticleExtractor, Sendable {
    public init() {}

    public func extractArticle(from html: String, url: URL) -> CleanArticle? {
        var working = html
        working = stripComments(working)
        // Title/metadata are read from the original document above; the head
        // must not contribute body text or it leaks into empty-page results.
        working = stripElements(working, tags: ["head", "script", "style", "noscript", "template", "svg", "canvas", "iframe"])
        working = stripBoilerplateContainers(working)

        let title = HTMLContentExtractor.extractTitle(from: html)
        let author = extractMetaContent(from: html, attribute: "name", value: "author")
        let publishedAt = extractPublishedDate(from: html)

        let scope: String
        if let scoped = preferredScope(in: working) {
            scope = scoped
        } else {
            scope = working
        }
        let headings = extractHeadings(from: scope)
        guard let body = bestCandidateBody(in: scope) else { return nil }
        let text = HTMLContentExtractor.decodeBasicHTMLEntities(body)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CleanArticle(
            url: url,
            title: title,
            author: author,
            publishedAt: publishedAt,
            text: text,
            headings: headings,
            method: .staticFetch
        )
    }

    // MARK: - Stages

    private func stripComments(_ html: String) -> String {
        html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    }

    private func stripElements(_ html: String, tags: [String]) -> String {
        var result = html
        for tag in tags {
            result = result.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>|<\(tag)\\b[^>]*/>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Removes navigation, chrome, and advertising containers while keeping
    /// the readable body. Class/id matching is intentionally narrow so
    /// article bodies are never discarded by an over-broad pattern.
    private func stripBoilerplateContainers(_ html: String) -> String {
        var result = stripElements(html, tags: ["nav", "footer", "aside", "form", "header"])
        let boilerplate = "(ad|ads|advert|banner|promo|popup|modal|cookie|consent|newsletter|subscribe|signup|sidebar|widget|related|recommend|sponsor|social-share|comments|comment-list|breadcrumb|pagination|site-(nav|header|footer))"
        result = result.replacingOccurrences(
            of: "<(div|section)[^>]*(?:id|class)=\"[^\"]*(?:\(boilerplate))[^\"]*\"[^>]*>[\\s\\S]*?</\\1\\s*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    private func preferredScope(in html: String) -> String? {
        for tag in ["article", "main"] {
            let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)\\s*>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let scoped = String(html[range])
            if visibleCharacterCount(scoped) >= CleanArticle.minimumBodyCharacters {
                return scoped
            }
        }
        return nil
    }

    /// Scores each `div`/`section` by paragraph text density; falls back to
    /// the whole scope when no container clearly wins.
    private func bestCandidateBody(in scope: String) -> String? {
        let pattern = "<(div|section)\\b[^>]*>([\\s\\S]*?)</\\1\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return plainText(scope)
        }
        let range = NSRange(scope.startIndex..., in: scope)
        let matches = regex.matches(in: scope, range: range)
        var best: (score: Int, text: String)?
        for match in matches {
            guard let inner = Range(match.range(at: 2), in: scope) else { continue }
            let candidate = String(scope[inner])
            let paragraphs = paragraphTexts(in: candidate)
            let chars = paragraphs.joined().count
            guard chars >= 120 else { continue }
            let score = chars + paragraphs.count * 60
            if score > (best?.score ?? 0), let text = plainText(candidate), !text.isEmpty {
                best = (score, text)
            }
        }
        if let best { return best.text }
        return plainText(scope)
    }

    private func paragraphTexts(in html: String) -> [String] {
        let pattern = "<p\\b[^>]*>([\\s\\S]*?)</p\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: html) else { return nil }
            let text = plainText(String(html[inner]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.count >= 40 ? text : nil
        }
    }

    private func plainText(_ html: String) -> String? {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = stripped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func visibleCharacterCount(_ html: String) -> Int {
        plainText(html)?.count ?? 0
    }

    private func extractHeadings(from html: String) -> [String] {
        let pattern = "<h[12]\\b[^>]*>([\\s\\S]*?)</h[12]\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: html),
                  let text = plainText(String(html[inner]))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return String(text.prefix(300))
        }
    }

    private func extractMetaContent(from html: String, attribute: String, value: String) -> String? {
        let pattern = "<meta\\b[^>]*\(attribute)=\"\(value)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let tagRange = Range(match.range(at: 0), in: html)
        else { return nil }
        let tag = String(html[tagRange])
        let contentPattern = "content=\"([^\"]*)\""
        guard let contentRegex = try? NSRegularExpression(pattern: contentPattern, options: .caseInsensitive),
              let contentMatch = contentRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let contentRange = Range(contentMatch.range(at: 1), in: tag)
        else { return nil }
        let content = String(tag[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private func extractPublishedDate(from html: String) -> Date? {
        if let iso = extractMetaContent(from: html, attribute: "property", value: "article:published_time"),
           let date = ISO8601DateFormatter().date(from: iso) {
            return date
        }
        let pattern = "<time\\b[^>]*datetime=\"([^\"]*)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let datetimeRange = Range(match.range(at: 1), in: html)
        else { return nil }
        return ISO8601DateFormatter().date(from: String(html[datetimeRange]))
    }
}
