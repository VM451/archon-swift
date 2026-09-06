import Foundation
import ArchonCore

/// Fast, dependency-free helpers for turning raw HTML into plain text,
/// extracting a title, and splitting semantic highlights.
internal struct HTMLContentExtractor {
    
    static func fetchStaticPage(url: URL, timeout: TimeInterval = 5.0) async throws -> (title: String, text: String, html: String) {
        guard SearchURLPolicy.validateRemoteOrLocalFile(url) else {
            throw SearchError.extractionFailed(reason: "Only public HTTP(S) URLs or bounded local files are supported.")
        }
        let html: String
        if url.isFileURL {
            let resolved = url.resolvingSymlinksInPath()
            guard let data = try? Data(contentsOf: resolved), data.count <= SearchURLPolicy.maxResponseBytes,
                  let string = String(data: data, encoding: .utf8) else {
                throw SearchError.extractionFailed(reason: "Local file is unreadable or exceeds the 8 MB limit.")
            }
            html = string
        } else {
            try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "Search page fetch")
            do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            for (key, value) in StealthHeaders.standardHeaders() {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await SearchURLPolicy.makeSession().data(for: request)
            guard data.count <= SearchURLPolicy.maxResponseBytes else {
                throw SearchError.extractionFailed(reason: "Response exceeds the 8 MB limit.")
            }
            guard let finalURL = (response as? HTTPURLResponse)?.url,
                  SearchURLPolicy.validate(finalURL) else {
                throw SearchError.extractionFailed(reason: "Redirected response target is not a permitted public URL.")
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                throw SearchError.networkFailure(urlString: url.absoluteString, statusCode: statusCode)
            }
            guard let string = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            html = string
            }
        }
        guard html.utf8.count <= SearchURLPolicy.maxResponseBytes else {
            throw SearchError.extractionFailed(reason: "Response exceeds the 8 MB limit.")
        }
        
        let title = extractTitle(from: html)
        let text = extractText(from: html)
        return (title, text, html)
    }
    
    static func extractTitle(from html: String) -> String {
        let pattern = #"<title[^>]*>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return ""
        }
        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let titleRange = Range(match.range(at: 1), in: html) {
            return String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
    
    static func extractText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style\\b[^<]*(?:(?!<\\/style>)<[^<]*)*<\\/style>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
        text = decodeBasicHTMLEntities(text)
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static func decodeBasicHTMLEntities(_ text: String) -> String {
        var decoded = text
        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " ")
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }
    
    static func highlights(from context: String, maxHighlights: Int) -> [String] {
        return context
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }
            .prefix(maxHighlights)
            .map { String($0) }
    }
}
