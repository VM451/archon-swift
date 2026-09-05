import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Defines the source engine/directory to run discovery queries against.
public enum DiscoverySource: Sendable, Codable, Hashable {
    case duckDuckGo
    case wikipedia
    case localWorkspace(directoryPath: String)
    case socialMedia(platforms: [SocialPlatform])

    /// Searches every supported platform through public indexed web results.
    public static var allSocialMedia: Self {
        .socialMedia(platforms: SocialPlatform.allCases)
    }
}

public struct DiscoveryEngine: Sendable {
    private let session: URLSession
    
    public init(session: URLSession? = nil) {
        self.session = session ?? SearchURLPolicy.makeSession()
    }
    
    /// Queries the selected search source for target URLs.
    /// - Parameters:
    ///   - query: The user search query.
    ///   - source: The target discovery source.
    /// - Returns: An array of normalized target URLs.
    public func search(query: String, source: DiscoverySource = .duckDuckGo) async throws -> [URL] {
        switch source {
        case .duckDuckGo:
            return try await searchDuckDuckGo(query: query)
        case .wikipedia:
            return try await searchWikipedia(query: query)
        case .localWorkspace(let directoryPath):
            return try await searchLocalWorkspace(query: query, directoryPath: directoryPath)
        case .socialMedia(let platforms):
            return try await searchSocialMedia(query: query, platforms: platforms)
        }
    }
    
    /// Queries DuckDuckGo HTML interface for organic search results.
    private func searchDuckDuckGo(query: String) async throws -> [URL] {
        guard let url = Self.duckDuckGoURL(for: query) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, val) in StealthHeaders.standardHeaders() {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        guard let htmlString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        return parseSERP(htmlString)
    }

    /// Searches each selected platform concurrently and preserves the declared platform order.
    /// A blocked or unavailable platform does not discard results from the remaining platforms.
    private func searchSocialMedia(query: String, platforms: [SocialPlatform]) async throws -> [URL] {
        let selectedPlatforms = platforms.isEmpty ? SocialPlatform.allCases : platforms
        try Task.checkCancellation()

        let indexedResults = try await withThrowingTaskGroup(of: IndexedSocialResults.self, returning: [IndexedSocialResults].self) { group in
            var platformIterator = selectedPlatforms.enumerated().makeIterator()
            let maxConcurrentQueries = 3

            for _ in 0..<min(maxConcurrentQueries, selectedPlatforms.count) {
                guard let (index, platform) = platformIterator.next() else { break }
                group.addTask {
                    do {
                        let scopedQuery = Self.socialSearchQuery(for: platform, query: query)
                        let urls = try await self.searchDuckDuckGo(query: scopedQuery)
                        return IndexedSocialResults(index: index, urls: urls)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return IndexedSocialResults(index: index, urls: [])
                    }
                }
            }

            var results = [IndexedSocialResults]()
            while let result = try await group.next() {
                results.append(result)
                if let (index, platform) = platformIterator.next() {
                    group.addTask {
                        do {
                            let scopedQuery = Self.socialSearchQuery(for: platform, query: query)
                            let urls = try await self.searchDuckDuckGo(query: scopedQuery)
                            return IndexedSocialResults(index: index, urls: urls)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return IndexedSocialResults(index: index, urls: [])
                        }
                    }
                }
            }
            return results.sorted { $0.index < $1.index }
        }

        var uniqueURLs = Set<String>()
        var urls = [URL]()
        for result in indexedResults {
            for url in result.urls {
                if uniqueURLs.insert(url.absoluteString).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    /// Builds a public-index query such as `site:reddit.com Swift concurrency`.
    internal static func socialSearchQuery(for platform: SocialPlatform, query: String) -> String {
        let siteScope = platform.searchDomains
            .map { "site:\($0)" }
            .joined(separator: " OR ")
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty ? siteScope : "(\(siteScope)) \(trimmedQuery)"
    }

    private static func duckDuckGoURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
    
    /// Queries Wikipedia open search API for matching page URLs.
    private func searchWikipedia(query: String) async throws -> [URL] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encodedQuery)&limit=10&namespace=0&format=json") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, val) in StealthHeaders.standardHeaders() {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let jsonArray = json as? [Any], jsonArray.count >= 4,
              let urlStrings = jsonArray[3] as? [String] else {
            return []
        }
        
        return urlStrings.compactMap { URL(string: $0) }.filter(SearchURLPolicy.validate)
    }
    
    /// Indexes and searches a local directory path for documents matching search terms.
    private func searchLocalWorkspace(query: String, directoryPath: String) async throws -> [URL] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        
        guard let enumerator = fileManager.enumerator(atPath: directoryPath) else {
            return []
        }
        
        let rootURL = URL(fileURLWithPath: directoryPath).standardizedFileURL.resolvingSymlinksInPath()
        var urls = [URL]()
        let maxScannedEntries = 25_000
        var scannedEntries = 0
        var scannedFiles = 0
        var scannedBytes = 0
        let queryTerms = query.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        while scannedEntries < maxScannedEntries,
              let fileRelativePath = enumerator.nextObject() as? String {
            try Task.checkCancellation()
            scannedEntries += 1
            let fileURL = URL(fileURLWithPath: directoryPath).appendingPathComponent(fileRelativePath)
            let pathExtension = fileURL.pathExtension.lowercased()
            if pathExtension == "txt" || pathExtension == "md" {
                do {
                    let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                    let rootPath = rootURL.path.hasSuffix("/") ? String(rootURL.path.dropLast()) : rootURL.path
                    guard resolvedURL.path.hasPrefix(rootPath + "/"),
                          let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path),
                          let size = attributes[.size] as? NSNumber,
                          size.intValue <= 1_048_576,
                          scannedFiles < 1_000,
                          scannedBytes + size.intValue <= 50 * 1_024 * 1_024 else { continue }
                    let content = try String(contentsOf: resolvedURL, encoding: .utf8)
                    scannedFiles += 1
                    scannedBytes += size.intValue
                    let lowerContent = content.lowercased()
                    let matches = queryTerms.isEmpty ? true : queryTerms.contains { lowerContent.contains($0) }
                    if matches {
                        urls.append(fileURL)
                    }
                } catch {
                    // Ignore unreadable files
                }
            }
        }
        
        return urls
    }
    
    /// Parses raw HTML from DuckDuckGo SERP and extracts external organic links.
    internal func parseSERP(_ html: String) -> [URL] {
        var foundURLs = [URL]()
        var uniqueURLs = Set<String>()
        
        let pattern = #"href=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        
        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[hrefRange])
            
            if href.contains("uddg=") {
                if let decodedStr = extractTargetURL(from: href),
                   let normalized = normalize(urlString: decodedStr) {
                    let absoluteString = normalized.absoluteString
                    if !uniqueURLs.contains(absoluteString) {
                        uniqueURLs.insert(absoluteString)
                        foundURLs.append(normalized)
                    }
                }
            } else if href.hasPrefix("http") && !href.contains("duckduckgo.com") {
                if let normalized = normalize(urlString: href) {
                    let absoluteString = normalized.absoluteString
                    if !uniqueURLs.contains(absoluteString) {
                        uniqueURLs.insert(absoluteString)
                        foundURLs.append(normalized)
                    }
                }
            }
        }
        
        return foundURLs
    }
    
    /// Extracts the actual target URL from the DuckDuckGo redirect link.
    private func extractTargetURL(from link: String) -> String? {
        let fullLink = link.hasPrefix("//") ? "https:" + link : (link.hasPrefix("/") ? "https://duckduckgo.com" + link : link)
        
        guard let components = URLComponents(string: fullLink),
              let queryItems = components.queryItems else {
            return nil
        }
        
        return queryItems.first(where: { $0.name == "uddg" })?.value
    }
    
    /// Normalizes URLs by stripping tracking queries and fragments.
    private func normalize(urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }
        
        if components.scheme == nil {
            components.scheme = "https"
        }
        
        if let queryItems = components.queryItems {
            let cleanItems = queryItems.filter { item in
                let lowerName = item.name.lowercased()
                return !lowerName.hasPrefix("utm_") &&
                       lowerName != "gclid" &&
                       lowerName != "fbclid" &&
                       lowerName != "_hsenc" &&
                       lowerName != "mkt_tok" &&
                       lowerName != "affiliate"
            }
            components.queryItems = cleanItems.isEmpty ? nil : cleanItems
        }
        
        components.fragment = nil
        
        guard let url = components.url, SearchURLPolicy.validate(url) else { return nil }
        return url
    }
}

private struct IndexedSocialResults: Sendable {
    let index: Int
    let urls: [URL]
}
