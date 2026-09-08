import Foundation
import ArchonCore

/// Actor coordinating two-stage local article extraction without third-party cloud services.
public actor NativeReader: Sendable {
    public static let minimumBodyCharacters = 400

    private let session: URLSession
    private let extractor: SwiftSoupArticleExtractor
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        extractor: SwiftSoupArticleExtractor = SwiftSoupArticleExtractor(),
        timeout: TimeInterval = 15.0
    ) {
        self.session = session
        self.extractor = extractor
        self.timeout = timeout
    }

    /// Reads a webpage using two-stage local extraction.
    ///
    /// - Stage 1: Fast static `URLSession` fetch analyzed via `SwiftSoupArticleExtractor`.
    /// - Stage 2: If static content is thin (< 400 chars), escalates to `ReadabilityWebKitBridge` on `@MainActor`.
    public func read(url: URL) async throws -> WebDocument {
        guard SearchURLPolicy.validate(url) else {
            throw SearchError.invalidURL(urlString: url.absoluteString)
        }
        try ArchonNetworkSecurity.ensureRemoteNetworkAllowed(provider: "NativeReader")
        try Task.checkCancellation()

        let stage1Doc = await fetchAndExtractStatic(url: url)
        if let stage1Doc, stage1Doc.text.count >= Self.minimumBodyCharacters {
            return stage1Doc
        }

        do {
            try Task.checkCancellation()
            let bridge = await ReadabilityWebKitBridge()
            let extracted = try await bridge.extract(url: url, timeout: timeout)
            if extracted.text.count >= Self.minimumBodyCharacters || stage1Doc == nil {
                return WebDocument(
                    url: url,
                    title: extracted.title,
                    text: extracted.text,
                    markdown: extracted.markdown,
                    publishedAt: extracted.publishedAt,
                    metadata: extracted.metadata
                )
            }
        } catch {
            if let fallback = stage1Doc, !fallback.text.isEmpty {
                return fallback
            }
            throw error
        }

        if let fallback = stage1Doc, !fallback.text.isEmpty {
            return fallback
        }

        throw SearchError.extractionFailed(reason: "NativeReader could not extract readable content from \(url.absoluteString)")
    }

    private func fetchAndExtractStatic(url: URL) async -> WebDocument? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue(StealthHeaders.randomUserAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                return nil
            }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard let extracted = extractor.extract(html: html, url: url) else {
                return nil
            }
            return WebDocument(
                url: url,
                title: extracted.title,
                text: extracted.text,
                markdown: extracted.markdown,
                publishedAt: extracted.publishedAt,
                metadata: extracted.metadata
            )
        } catch {
            return nil
        }
    }
}
