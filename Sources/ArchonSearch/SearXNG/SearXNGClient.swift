import Foundation
import ArchonCore

/// Client actor for querying a SearXNG meta-search instance over HTTP.
public actor SearXNGClient: Sendable {
    public let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        if let endpoint {
            self.endpoint = endpoint
        } else if let fallback = URL(string: "http://localhost:8080") {
            self.endpoint = fallback
        } else {
            self.endpoint = URL(fileURLWithPath: "/")
        }
        self.session = session
    }

    /// Dispatches a search query to the SearXNG instance and maps results to `SearchResult`.
    public func search(
        _ query: String,
        categories: [String]? = nil,
        engines: [String]? = nil,
        page: Int = 1
    ) async throws -> [SearchResult] {
        try ensureNetworkAllowed()
        let request = SearXNGRequest(
            query: query,
            categories: categories,
            engines: engines,
            pageno: page
        )
        guard let url = request.makeURL(baseURL: endpoint) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.networkFailure(urlString: url.absoluteString, statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SearXNGResponse.self, from: data)
        return decoded.results.compactMap { raw in
            guard let resultURL = URL(string: raw.url) else { return nil }
            let snippet = raw.content ?? ""
            let highlights = snippet.isEmpty ? [] : [snippet]
            return SearchResult(
                url: resultURL,
                title: raw.title,
                snippet: snippet,
                highlights: highlights,
                score: raw.score,
                engine: raw.engine
            )
        }
    }

    /// Verifies availability of the SearXNG endpoint via health check or root status.
    public func checkHealth() async -> Bool {
        guard let healthURL = URL(string: "healthz", relativeTo: endpoint)?.absoluteURL else {
            return false
        }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                return true
            }
            var rootRequest = URLRequest(url: endpoint)
            rootRequest.httpMethod = "GET"
            rootRequest.timeoutInterval = 3.0
            let (_, rootResponse) = try await session.data(for: rootRequest)
            guard let rootHTTP = rootResponse as? HTTPURLResponse else { return false }
            return (200...399).contains(rootHTTP.statusCode)
        } catch {
            return false
        }
    }

    private func ensureNetworkAllowed() throws {
        let host = endpoint.host?.lowercased() ?? ""
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if loopbackHosts.contains(host) {
            try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(endpoint, provider: "SearXNG")
        } else {
            try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "SearXNG")
        }
    }
}
