import Foundation
import ArchonCore

/// Internal response envelope used by some Crawl4AI deployments.
private struct Crawl4AIEnvelope: Codable {
    let results: [Crawl4AIResponse]?
}

/// Client actor for dispatching extraction jobs to a Crawl4AI microservice over HTTP.
public actor Crawl4AIClient: Sendable {
    public let endpoint: URL
    public let apiToken: String?
    private let session: URLSession

    public init(
        endpoint: URL? = nil,
        apiToken: String? = nil,
        session: URLSession = .shared
    ) {
        if let endpoint {
            self.endpoint = endpoint
        } else if let fallback = URL(string: "http://localhost:11235") {
            self.endpoint = fallback
        } else {
            self.endpoint = URL(fileURLWithPath: "/")
        }
        self.apiToken = apiToken
        self.session = session
    }

    /// Crawls a target URL using Crawl4AI and maps the result into a `WebDocument`.
    public func crawl(url: URL, options: CrawlOptions = CrawlOptions()) async throws -> WebDocument {
        try ensureNetworkAllowed()
        let crawlEndpoint = endpoint.appendingPathComponent("crawl")
        var request = URLRequest(url: crawlEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let payload = Crawl4AIRequest(url: url, options: options)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.networkFailure(urlString: crawlEndpoint.absoluteString, statusCode: http.statusCode)
        }

        let crawlResponse = try decodeResponse(from: data)
        guard crawlResponse.success else {
            let reason = crawlResponse.errorMessage ?? "Crawl4AI extraction failed"
            throw SearchError.extractionFailed(reason: reason)
        }

        let selectedMarkdown: String
        if let fit = crawlResponse.markdown?.fitMarkdown, !fit.isEmpty {
            selectedMarkdown = fit
        } else if let raw = crawlResponse.markdown?.rawMarkdown, !raw.isEmpty {
            selectedMarkdown = raw
        } else {
            selectedMarkdown = ""
        }

        let docURL = URL(string: crawlResponse.url) ?? url
        let title = crawlResponse.metadata?["title"] ?? ""
        let textContent = crawlResponse.fitHtml ?? crawlResponse.html ?? selectedMarkdown
        return WebDocument(
            url: docURL,
            title: title,
            text: textContent,
            markdown: selectedMarkdown,
            publishedAt: nil,
            metadata: crawlResponse.metadata ?? [:]
        )
    }

    /// Checks the health and schema readiness of the Crawl4AI microservice.
    public func checkHealth() async -> Bool {
        let paths = ["healthz", "schema"]
        for path in paths {
            guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0
            if let apiToken, !apiToken.isEmpty {
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    private func decodeResponse(from data: Data) throws -> Crawl4AIResponse {
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(Crawl4AIResponse.self, from: data) {
            return single
        }
        if let array = try? decoder.decode([Crawl4AIResponse].self, from: data), let first = array.first {
            return first
        }
        if let envelope = try? decoder.decode(Crawl4AIEnvelope.self, from: data), let first = envelope.results?.first {
            return first
        }
        return try decoder.decode(Crawl4AIResponse.self, from: data)
    }

    private func ensureNetworkAllowed() throws {
        let host = endpoint.host?.lowercased() ?? ""
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if loopbackHosts.contains(host) {
            try ArchonNetworkSecurity.ensureLoopbackEndpointAllowed(endpoint, provider: "Crawl4AI")
        } else {
            try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "Crawl4AI")
        }
    }
}
