import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArchonCore

public struct RobotsRules: Sendable {
    public let disallowPaths: [String]
    public let crawlDelay: TimeInterval?
    
    public init(disallowPaths: [String] = [], crawlDelay: TimeInterval? = nil) {
        self.disallowPaths = disallowPaths
        self.crawlDelay = crawlDelay
    }
}

public actor RobotsParser {
    private var cache = [String: RobotsRules]()
    private var unavailable = Set<String>()
    private let session: URLSession
    
    public init(session: URLSession? = nil) {
        self.session = session ?? SearchURLPolicy.makeSession()
    }
    
    /// Fetches robots.txt for the given host and parses it.
    /// Results are cached in the actor.
    public func rules(for url: URL) async -> RobotsRules {
        guard let robotsURL = Self.robotsURL(for: url) else {
            return RobotsRules()
        }
        let cacheKey = robotsURL.absoluteString.lowercased()
        guard !unavailable.contains(cacheKey) else { return RobotsRules() }
        if let cached = cache[cacheKey] {
            return cached
        }
        if ArchonNetworkSecurity.isZeroCloudEnabled {
            unavailable.insert(cacheKey)
            return RobotsRules()
        }
        
        var request = URLRequest(url: robotsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= SearchURLPolicy.maxResponseBytes else {
                unavailable.insert(cacheKey)
                return RobotsRules()
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                unavailable.insert(cacheKey)
                return RobotsRules()
            }
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                let emptyRules = RobotsRules()
                cache[cacheKey] = emptyRules
                return emptyRules
            }
            guard httpResponse.statusCode == 200 else {
                unavailable.insert(cacheKey)
                return RobotsRules()
            }
            
            if let content = String(data: data, encoding: .utf8) {
                let parsedRules = parse(content, forUserAgent: "*")
                cache[cacheKey] = parsedRules
                return parsedRules
            }
        } catch {
            unavailable.insert(cacheKey)
            return RobotsRules()
        }
        
        unavailable.insert(cacheKey)
        return RobotsRules()
    }
    
    /// Checks if a URL can be crawled according to its host's robots.txt rules.
    public func canCrawl(_ url: URL) async -> Bool {
        guard let robotsURL = Self.robotsURL(for: url) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let rules = await rules(for: url)
        guard !unavailable.contains(robotsURL.absoluteString.lowercased()) else { return false }
        
        for disallow in rules.disallowPaths {
            if disallow == "/" {
                return false
            }
            if !disallow.isEmpty && path.hasPrefix(disallow) {
                return false
            }
        }
        
        return true
    }

    private static func robotsURL(for url: URL) -> URL? {
        guard SearchURLPolicy.validate(url), let host = url.host?.lowercased() else {
            return nil
        }
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = host
        components.port = url.port
        components.path = "/robots.txt"
        guard let robotsURL = components.url, SearchURLPolicy.validate(robotsURL) else {
            return nil
        }
        return robotsURL
    }
    
    /// Returns the crawl delay specified in the robots.txt.
    public func crawlDelay(for url: URL) async -> TimeInterval? {
        let rules = await rules(for: url)
        return rules.crawlDelay
    }
    
    /// Parses robots.txt file contents for a specific user agent.
    internal func parse(_ content: String, forUserAgent targetAgent: String) -> RobotsRules {
        var disallowPaths = [String]()
        var crawlDelay: TimeInterval? = nil
        
        let lines = content.components(separatedBy: .newlines)
        var appliesToUs = false
        let targetLower = targetAgent.lowercased()
        
        for line in lines {
            // Strip comments
            let cleanLine = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = cleanLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            
            if key == "user-agent" {
                let agent = value.lowercased()
                appliesToUs = (agent == "*" || agent == targetLower)
            } else if appliesToUs {
                if key == "disallow" {
                    if !value.isEmpty {
                        disallowPaths.append(value)
                    }
                } else if key == "crawl-delay" {
                    if let delaySeconds = Double(value), delaySeconds.isFinite, delaySeconds >= 0 {
                        crawlDelay = min(delaySeconds, 300)
                    }
                }
            }
        }
        
        return RobotsRules(disallowPaths: disallowPaths, crawlDelay: crawlDelay)
    }
}
