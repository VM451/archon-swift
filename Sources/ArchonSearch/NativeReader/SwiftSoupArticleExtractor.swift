import Foundation

#if canImport(SwiftSoup)
import SwiftSoup
#endif

/// HTML cleaner and article extractor that strips boilerplate, preserves article content,
/// and converts structured article elements into clean plain text and Markdown.
public struct SwiftSoupArticleExtractor: ArticleExtractor, Sendable {
    public init() {}

    public func extract(html: String, url: URL) -> ExtractedArticle? {
        #if canImport(SwiftSoup)
        return extractWithSwiftSoup(html: html, url: url)
        #else
        return extractWithNativeHeuristic(html: html, url: url)
        #endif
    }

    public func extractArticle(from html: String, url: URL) -> CleanArticle? {
        guard let extracted = extract(html: html, url: url) else { return nil }
        return CleanArticle(
            url: url,
            title: extracted.title,
            author: extracted.author,
            publishedAt: extracted.publishedAt,
            text: extracted.text,
            headings: extracted.headings,
            method: .staticFetch
        )
    }

    #if canImport(SwiftSoup)
    private func extractWithSwiftSoup(html: String, url: URL) -> ExtractedArticle? {
        guard let doc = try? SwiftSoup.parse(html, url.absoluteString) else { return nil }
        _ = try? doc.select("head script, head style, script, style, noscript, template, svg, iframe, canvas").remove()
        _ = try? doc.select("nav, header, footer, aside, form, [aria-modal='true']").remove()
        let adSelectors = ".ad, .ads, .banner, .cookie, .consent, .modal, .popup, .newsletter, .promo, #cookie-banner, #consent-banner"
        _ = try? doc.select(adSelectors).remove()

        let title = (try? doc.title()) ?? HTMLContentExtractor.extractTitle(from: html)
        let author = (try? doc.select("meta[name=author]").attr("content")) ?? (try? doc.select("meta[property='article:author']").attr("content"))
        let publishedAt = extractDate(from: html)
        let headings = (try? doc.select("h1, h2, h3, h4").array().compactMap { try? $0.text() }.filter { !$0.isEmpty }) ?? []

        guard let target = (try? doc.select("article").first()) ?? (try? doc.select("main").first()) ?? doc.body() else { return nil }
        guard let text = try? target.text(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let md = convertToMarkdown(element: target)
        return ExtractedArticle(title: title, author: author?.isEmpty == true ? nil : author, publishedAt: publishedAt, headings: headings, text: text, markdown: md)
    }

    private func convertToMarkdown(element: SwiftSoup.Element) -> String {
        guard let html = try? element.html() else { return (try? element.text()) ?? "" }
        return Self.htmlToMarkdown(html)
    }
    #endif

    private func extractWithNativeHeuristic(html: String, url: URL) -> ExtractedArticle? {
        let heuristic = HeuristicArticleExtractor()
        guard let article = heuristic.extractArticle(from: html, url: url) else { return nil }
        let title = article.title.isEmpty ? HTMLContentExtractor.extractTitle(from: html) : article.title
        let markdown = Self.htmlToMarkdown(html, fallbackText: article.text)
        return ExtractedArticle(
            title: title,
            author: article.author,
            publishedAt: article.publishedAt,
            headings: article.headings,
            text: article.text,
            markdown: markdown
        )
    }

    private static func htmlToMarkdown(_ html: String, fallbackText: String? = nil) -> String {
        var s = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(script|style|nav|header|footer|aside)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<h1\\b[^>]*>(.*?)</h1>", with: "\n# $1\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<h2\\b[^>]*>(.*?)</h2>", with: "\n## $1\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<h3\\b[^>]*>(.*?)</h3>", with: "\n### $1\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li\\b[^>]*>(.*?)</li>", with: "\n- $1", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<p\\b[^>]*>(.*?)</p>", with: "\n\n$1\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<a\\b[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", with: "[$2]($1)", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = HTMLContentExtractor.decodeBasicHTMLEntities(s)
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? (fallbackText ?? "") : s
    }

    private func extractDate(from html: String) -> Date? {
        let pattern = "content=\"(\\d{4}-\\d{2}-\\d{2}[T\\d:Z+.-]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, range: range), let r = Range(match.range(at: 1), in: html) {
            return ISO8601DateFormatter().date(from: String(html[r]))
        }
        return nil
    }
}
