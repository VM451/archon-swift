import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@FoundationModels.Generable
public struct ReadWebPageArguments: Sendable, Codable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}
#else
public struct ReadWebPageArguments: Sendable, Codable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}
#endif

/// High-level webpage reader tool converting web pages into clean Markdown or text.
public struct ReadWebPageTool: Tool, Sendable {
    public let name = "read_web_page"
    public let description = "Extracts readable text and markdown from a web URL using native parsing or crawler backends."
    public let router: RetrievalRouter

    public init(router: RetrievalRouter) {
        self.router = router
    }

    public init(crawlClient: Crawl4AIClient? = nil, nativeReader: NativeReader = NativeReader()) {
        self.router = RetrievalRouter(crawlClient: crawlClient, nativeReader: nativeReader)
    }

    /// Primary structured execution entry point.
    public func execute(urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SearchError.invalidURL(urlString: urlString)
        }
        let doc = try await router.read(url: url)
        let content = doc.markdown.isEmpty ? doc.text : doc.markdown
        return "# \(doc.title)\nURL: \(doc.url.absoluteString)\n\n\(content)"
    }

    /// Invokes the tool using a JSON string.
    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = json["url"] as? String else {
            throw SearchError.extraction(reason: "read_web_page requires a 'url' string parameter.")
        }
        return try await execute(urlString: urlString)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
extension ReadWebPageTool: FoundationModels.Tool {
    public typealias Arguments = ReadWebPageArguments
    public typealias Output = String

    public func call(arguments: ReadWebPageArguments) async throws -> String {
        try await execute(urlString: arguments.url)
    }
}
#endif
