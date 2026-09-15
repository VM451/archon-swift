import Foundation

/// Multi-engine fan-out registry (SEARCH-004: SerpAPI/SearXNG answer).
///
/// Host apps register named `SearchEngine` adapters (DuckDuckGo, SearXNG,
/// future Brave/Tavily/Exa adapters with host-owned credentials). Fan-out is
/// concurrent with per-engine failure isolation, deterministic URL dedupe,
/// and cancellation checks. No vendor types leak; no new dependencies.
public actor SearchEngineRegistry: Sendable {
    private var engines: [(name: String, engine: any SearchEngine)] = []

    public init() {}

    public func register(name: String, engine: any SearchEngine) {
        engines.removeAll { $0.name == name }
        engines.append((name, engine))
    }

    public func remove(name: String) {
        engines.removeAll { $0.name == name }
    }

    public var names: [String] { engines.map(\.name) }

    public func searchAll(_ query: String, categories: [String]? = nil, page: Int = 1, limit: Int = 10) async -> [SearchResult] {
        try? Task.checkCancellation()
        var collected: [SearchResult] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for entry in engines {
                group.addTask {
                    do {
                        return try await entry.engine.search(query, categories: categories, page: page)
                    } catch {
                        return []
                    }
                }
            }
            for await partial in group {
                collected.append(contentsOf: partial)
            }
        }
        try? Task.checkCancellation()
        return Self.dedupe(collected, limit: limit)
    }

    public static func dedupe(_ results: [SearchResult], limit: Int) -> [SearchResult] {
        var seen = Set<String>()
        var out: [SearchResult] = []
        for result in results {
            let key = normalize(result.url)
            guard seen.insert(key).inserted else { continue }
            out.append(result)
            if out.count >= max(0, limit) { break }
        }
        return out
    }

    private static func normalize(_ url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return (comps?.string ?? url.absoluteString).lowercased()
    }
}
