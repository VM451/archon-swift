import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SwiftSoup)
import SwiftSoup
#endif
import ArchonCore

/// Direct on-device search engine querying DuckDuckGo HTML endpoint.
public actor DuckDuckGoSearchEngine: SearchEngine {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? SearchURLPolicy.makeSession()
    }

    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult] {
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "DuckDuckGo search")
        guard var comp = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw SearchError.invalidURL(urlString: "https://html.duckduckgo.com/html/")
        }
        comp.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comp.url else { throw SearchError.invalidURL(urlString: query) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, val) in StealthHeaders.standardHeaders() {
            request.setValue(val, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.networkFailure(urlString: url.absoluteString, statusCode: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return parseHTML(html)
    }

    public func checkHealth() async -> Bool { true }

    private func parseHTML(_ html: String) -> [SearchResult] {
        #if canImport(SwiftSoup)
        let soup = parseSoup(html)
        if !soup.isEmpty { return soup }
        #endif
        return parseRegex(html)
    }

    #if canImport(SwiftSoup)
    private func parseSoup(_ html: String) -> [SearchResult] {
        guard let doc = try? SwiftSoup.parse(html),
              let elements = try? doc.select(".result, .web-result") else { return [] }
        return elements.compactMap { el in
            guard let a = try? el.select(".result__a").first(),
                  let title = try? a.text(), !title.isEmpty,
                  let href = try? a.attr("href"),
                  let url = resolveURL(href) else { return nil }
            let snippet = (try? el.select(".result__snippet").first()?.text()) ?? ""
            return SearchResult(title: title, url: url, snippet: snippet, engine: "duckduckgo")
        }
    }
    #endif

    private func parseRegex(_ html: String) -> [SearchResult] {
        let chunks = html.components(separatedBy: "result__body")
        let workingChunks = chunks.count > 1 ? Array(chunks.dropFirst()) : html.components(separatedBy: "result")
        var results: [SearchResult] = []
        let linkPattern = #"<a\b[^>]*class=["'][^"']*result__a[^"']*["'][^>]*>([\s\S]*?)</a>"#
        let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive)
        let hrefRegex = try? NSRegularExpression(pattern: #"href=["']([^"']+)["']"#, options: .caseInsensitive)
        let snipPattern = #"class=["'][^"']*result__snippet[^"']*["'][^>]*>([\s\S]*?)</"#
        let snippetRegex = try? NSRegularExpression(pattern: snipPattern, options: .caseInsensitive)
        for chunk in workingChunks {
            let range = NSRange(chunk.startIndex..., in: chunk)
            guard let lMatch = linkRegex?.firstMatch(in: chunk, range: range),
                  let lRange = Range(lMatch.range(at: 0), in: chunk),
                  let tRange = Range(lMatch.range(at: 1), in: chunk) else { continue }
            let tagStr = String(chunk[lRange])
            guard let hMatch = hrefRegex?.firstMatch(in: tagStr, range: NSRange(tagStr.startIndex..., in: tagStr)),
                  let hRange = Range(hMatch.range(at: 1), in: tagStr),
                  let url = resolveURL(String(tagStr[hRange])) else { continue }
            let title = stripHTML(String(chunk[tRange]))
            guard !title.isEmpty else { continue }
            let snippet: String
            if let sMatch = snippetRegex?.firstMatch(in: chunk, range: range),
               let sRange = Range(sMatch.range(at: 1), in: chunk) {
                snippet = stripHTML(String(chunk[sRange]))
            } else {
                snippet = ""
            }
            results.append(SearchResult(title: title, url: url, snippet: snippet, engine: "duckduckgo"))
        }
        return results
    }

    private func resolveURL(_ link: String) -> URL? {
        let clean = link.replacingOccurrences(of: "&amp;", with: "&")
        let full = clean.hasPrefix("//") ? "https:" + clean : (clean.hasPrefix("/") ? "https://duckduckgo.com" + clean : clean)
        guard let comp = URLComponents(string: full) else { return nil }
        let raw = comp.queryItems?.first(where: { $0.name == "uddg" })?.value ?? (full.hasPrefix("http") && !full.contains("duckduckgo.com") ? full : nil)
        guard let target = raw, var targetComp = URLComponents(string: target) else { return nil }
        if targetComp.scheme == nil { targetComp.scheme = "https" }
        targetComp.fragment = nil
        guard let url = targetComp.url, SearchURLPolicy.validate(url) else { return nil }
        return url
    }

    private func stripHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
