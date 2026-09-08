# ArchonSearch Reference

`ArchonSearch` 2.0 is the current-information retrieval, webpage extraction,
grounding, and autonomous research product of the Archon SDK. It delivers a
local-first, privacy-preserving pipeline that connects Apple-native applications
(iOS 27+, macOS 27+, visionOS 27+) to local meta-search engines,
in-process article extractors, headless microservices, prompt injection defenses,
citation integrity verification, and Liquid Glass conversational UI.

## Architecture & Companion Infrastructure

ArchonSearch is designed to operate locally without external third-party cloud
dependencies. Meta-search queries and complex browser automation are handled
via local companion containers configured in the root `docker-compose.yml`:

```bash
docker compose up -d
```

| Service | Image | Local Port | Protocol / Purpose |
| --- | --- | --- | --- |
| `searxng` | `searxng/searxng:latest` | `8080` | HTTP JSON meta-search (`/search?format=json`) aggregating multiple search providers. |
| `crawl4ai` | `unclecode/crawl4ai:latest` | `11235` | REST microservice (`/crawl`) for headless Playwright/Chromium extraction and Markdown generation. |

If companion containers are unreachable or network access is restricted,
ArchonSearch seamlessly falls back to native in-process extraction via
`NativeReader`.

---

## Core Types Reference

### 1. `ArchonSearchClient`
The high-level public actor facade conforming to the §10 Facade pattern. It hides
internal networking clients, parsers, and repositories behind a unified interface.

```swift
public actor ArchonSearchClient: Sendable {
    public let configuration: ArchonSearchConfiguration

    public init(
        configuration: ArchonSearchConfiguration = .localFirst(),
        database: SearchDatabase? = nil
    )

    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult]
    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument
    public func ask(query: String) async throws -> (context: String, sources: [Source], citations: [Citation])
    public func ask(_ query: String) async throws -> SearchAnswer
    public func research(topic: String, options: ResearchOptions = ResearchOptions()) async throws -> ResearchReport
    public func checkHealth() async -> (searxngHealthy: Bool, crawlerHealthy: Bool)
}
```

- `search(_:categories:page:)`: Dispatches queries to SearXNG and returns ranked `[SearchResult]`.
- `read(url:options:)`: Extracts clean text and Markdown from a URL using `RetrievalRouter`.
- `ask(query:)` / `ask(_:)`: Executes search, extracts source pages, encapsulates content inside `<reference_data>`, and verifies citations (returning tuple or `SearchAnswer`).
- `research(topic:options:)`: Executes autonomous multi-round iterative research.
- `checkHealth()`: Reports availability status of SearXNG and Crawl4AI endpoints.

---

### 2. `ArchonSearchConfiguration`
Value type governing routing decisions, endpoints, timeout limits, and capacity budgets.

```swift
public struct ArchonSearchConfiguration: Sendable, Codable, Equatable {
    public var routingMode: RoutingMode
    public var searchEngine: SearchEngineSettings
    public var crawler: CrawlerSettings
    public var timeouts: TimeoutSettings
    public var limits: LimitSettings

    public static func localFirst(
        searxngURL: URL? = URL(string: "http://localhost:8080"),
        crawl4aiURL: URL? = URL(string: "http://localhost:11235")
    ) -> ArchonSearchConfiguration
}
```

#### Settings Groups
- `SearchEngineSettings`: `searxngURL`, `enabledEngines: [String]`, `categories: [String]`, `language: String`, `safeSearch: Int`.
- `CrawlerSettings`: `crawl4aiURL`, `maxDepth: Int`, `maxConcurrentFetches: Int`, `userAgent: String?`, `respectRobotsTxt: Bool`, `renderJavaScript: Bool`.
- `TimeoutSettings`: `searchTimeout: TimeInterval` (default `10.0s`), `fetchTimeout: TimeInterval` (default `15.0s`), `totalLatencyBudget: TimeInterval?`.
- `LimitSettings`: `maxResults: Int` (default `10`), `maxPagesToScrape: Int` (default `3`), `maxSnippetCharacters: Int` (default `300`), `maxHighlights: Int` (default `3`).

---

### 3. `RetrievalRouter` & `RetrievalPolicy`
Actor coordinating page extraction between the headless `Crawl4AIClient` and the
native in-process `NativeReader`.

```swift
public actor RetrievalRouter: Sendable {
    public init(crawlClient: Crawl4AIClient? = nil, nativeReader: NativeReader = NativeReader())
    public init(configuration: ArchonSearchConfiguration)

    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument
    public func healthReport() async -> RetrievalHealthReport
}
```

#### Retrieval Policies (`ArchonSearchConfiguration.RoutingMode`)
- `.automatic`: Inspects `Crawl4AIClient` health. If healthy, uses Crawl4AI; if offline or failing, falls back to `NativeReader`.
- `.preferCrawler`: Dispatches to Crawl4AI first; falls back to `NativeReader` on error.
- `.preferNative`: Dispatches to `NativeReader` first; escalates to Crawl4AI on failure.
- `.crawlerOnly`: Dispatches exclusively to Crawl4AI. Throws `SearchError.crawl4ai` if unconfigured.
- `.nativeOnly`: Operates strictly in-process with zero network container dependencies.

#### `ReaderOptions`
Configures per-request routing overrides:
```swift
public struct ReaderOptions: Sendable, Codable, Hashable {
    public var mode: ArchonSearchConfiguration.RoutingMode
    public var timeout: TimeInterval?
    public var minBodyCharacters: Int // default 400
}
```

---

### 4. `SearXNGClient`
Actor managing HTTP JSON queries against a SearXNG instance without third-party trackers.

```swift
public actor SearXNGClient: Sendable {
    public let endpoint: URL

    public init(endpoint: URL? = nil, session: URLSession = .shared)

    public func search(
        _ query: String,
        categories: [String]? = nil,
        engines: [String]? = nil,
        page: Int = 1
    ) async throws -> [SearchResult]

    public func checkHealth() async -> Bool
}
```

---

### 5. `Crawl4AIClient`
Actor communicating with a Crawl4AI REST service to extract rich, structured Markdown from JavaScript-heavy targets.

```swift
public actor Crawl4AIClient: Sendable {
    public let endpoint: URL
    public let apiToken: String?

    public init(endpoint: URL? = nil, apiToken: String? = nil, session: URLSession = .shared)

    public func crawl(url: URL, options: CrawlOptions = CrawlOptions()) async throws -> WebDocument
    public func checkHealth() async -> Bool
}
```

---

### 6. `NativeReader`
Actor orchestrating two-stage, zero-cloud article extraction in-process.

```swift
public actor NativeReader: Sendable {
    public static let minimumBodyCharacters = 400

    public init(
        session: URLSession = .shared,
        extractor: SwiftSoupArticleExtractor = SwiftSoupArticleExtractor(),
        timeout: TimeInterval = 15.0
    )

    public func read(url: URL) async throws -> WebDocument
}
```

- **Stage 1**: Fast static fetch via `URLSession` analyzed with `SwiftSoupArticleExtractor`.
- **Escalation**: If extracted body length is `< 400` characters, escalates to Stage 2.
- **Stage 2**: Dispatches to `@MainActor` `ReadabilityWebKitBridge` to render JavaScript in an offscreen `WKWebView`.

---

### 7. `SwiftSoupArticleExtractor`
In-process DOM sanitizer and boilerplate remover.

```swift
public struct SwiftSoupArticleExtractor: ArticleExtractor, Sendable {
    public init()
    public func extract(html: String, url: URL) -> ExtractedArticle?
    public func extractArticle(from html: String, url: URL) -> CleanArticle?
}
```

- Strips `<script>`, `<style>`, `<nav>`, `<header>`, `<footer>`, `<aside>`, and `<form>`.
- Cleans cookie banners, modal overlays, and ad containers (`.ad`, `.ads`, `.banner`, `.cookie`, `#cookie-banner`).
- Identifies main content nodes (`<article>`, `<main>`, `<body>`).
- Converts HTML elements into clean Markdown syntax and extracts metadata (`title`, `author`, `publishedAt`, `headings`).

---

### 8. `ReadabilityWebKitBridge`
In-process WebKit delegate executing Mozilla Readability on dynamic single-page web applications.

```swift
@MainActor
public final class ReadabilityWebKitBridge: NSObject, WKNavigationDelegate, Sendable {
    public func extract(url: URL, timeout: TimeInterval = 15.0) async throws -> ExtractedArticle
}
```

- Isolated to `@MainActor` for WebKit compatibility.
- Applies anti-fingerprinting User-Agent headers.
- Supports cooperative `Task` cancellation and strict execution timeout bounds.

---

### 9. `ContextBuilder`
Constructs prompt-injection-safe grounding context for LLMs.

```swift
public struct ContextBuilder: Sendable {
    public var maxTokens: Int
    public var charsPerToken: Double

    public init(maxTokens: Int = 4000, charsPerToken: Double = 4.0)
    public init(maxCharacters: Int)

    public func buildContext(from sources: [Source], query: String? = nil) -> String
    public func buildContext(from documents: [WebDocument]) -> String
    public func wrapInReferenceData(_ content: String) -> String
    public func sanitizeText(_ input: String) -> String
}
```

- **XML Boundary Isolation**: Wraps untrusted external content in `<reference_data>` delimiters with critical security notices.
- **Injection Neutralization**: Strips adversarial tokens, including `ignore all previous instructions`, system tags, and delimiter tokens (`<|im_start|>`, `<|im_end|>`).
- **Token Budgeting**: Truncates snippets and documents to fit within designated token limits.

---

### 10. `CitationGraph`
Citation parser, claim validator, and deduplication engine eliminating model hallucinations.

```swift
public struct CitationGraph: Sendable {
    public init(sources: [Source] = [])
    public mutating func register(source: Source, index: Int)

    public func parseCitations(from text: String) -> [CitationReference]
    public func verify(citations: [CitationReference]) -> (valid: [CitationReference], hallucinations: [CitationReference])
    public func resolve(citations: [CitationReference]) -> [Citation]
    public func resolveCitations(in text: String) -> (unverified: [CitationReference], citations: [Citation])
    public static func tag(sourceIndex: Int, passageIndex: Int) -> String
}
```

- Parses citation patterns: `[SOURCE:S1/P2]`, `[S1]`, `[1]`, and `[S1/P1]`.
- Compares parsed citations against the registered set of retrieved sources.
- Segregates valid citations from hallucinated citations that lack supporting evidence.
- Resolves verified references into immutable `Citation` domain objects.

---

### 11. `SearchDatabase`
Actor managing local SQLite storage via GRDB with automated schema migrations.

```swift
public actor SearchDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(databasePath: String? = nil, inMemory: Bool = false) throws
    public init(dbWriter: any DatabaseWriter) throws

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T
    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T
}
```

#### Managed Tables
- `conversations`: Thread identifiers, titles, and timestamps.
- `messages`: Role, message text, and conversation associations.
- `search_sessions`: User queries, diagnostics JSON, and session metadata.
- `sources`: Source URLs, titles, and passage snapshots.
- `citations`: Citation labels, source linkages, and text snippets.
- `cache_entries`: Cached document HTML/Markdown with TTL expiration (`expiresAt`).

---

### 12. FoundationModels Tool Conformances
ArchonSearch provides tool conformances for both generic agent frameworks and Apple's
`FoundationModels.Tool` protocol with `@FoundationModels.Generable` arguments:

```swift
public struct WebSearchTool: Tool, Sendable {
    public let name: String = "web_search"
    public init(client: SearXNGClient)
    public func execute(query: String, maxResults: Int? = nil) async throws -> String
}

public struct ReadWebPageTool: Tool, Sendable {
    public let name: String = "read_web_page"
    public init(router: RetrievalRouter)
    public func execute(urlString: String) async throws -> String
}

public struct ResearchTool: Tool, Sendable {
    public let name: String = "deep_research"
    public init(coordinator: ResearchCoordinator)
    public func execute(topic: String, maxRounds: Int? = nil, maxDocuments: Int? = nil) async throws -> String
}
```

---

### 13. `ArchonChatView` & UI Components
Apple-native conversational UI conforming to Liquid Glass HIG.

```swift
public struct ArchonChatView: View {
    @State public var viewModel: ArchonChatViewModel

    public init(client: ArchonSearchClient)
    public init(viewModel: ArchonChatViewModel)
}
```

- `ArchonChatViewModel`: `@Observable @MainActor` class managing message history, query submission, and search mode (`.standard` vs. `.deepResearch`).
- `SearchComposerView`: Custom search bar with dynamic mode switching and animation.
- `CitationBadgeView`: Horizontal badge chips for inspecting cited sources.
- Adheres to HIG materials (`.ultraThinMaterial`, `Color.accentColor`), continuous corners, and Light/Dark mode parity.

---

## Code Examples

### 1. Initializing the Client
```swift
import ArchonSearch

// Local-first configuration targeting local Docker microservices
let client = ArchonSearchClient(configuration: .localFirst())

// Health check verifying local container connectivity
let (searxngOk, crawlerOk) = await client.checkHealth()
print("SearXNG: \(searxngOk), Crawl4AI: \(crawlerOk)")
```

### 2. Searching the Web
```swift
let results = try await client.search("Swift 6 strict concurrency", categories: ["it"])
for result in results {
    print("[\(result.title)] - \(result.url)")
    print("Snippet: \(result.snippet)\n")
}
```

### 3. Reading and Extracting Web Content
```swift
let url = URL(string: "https://developer.apple.com/documentation/swift")!
let document = try await client.read(
    url: url,
    options: ReaderOptions(mode: .automatic, timeout: 15.0)
)

print("Title: \(document.title)")
print("Extracted Content:\n\(document.markdown)")
```

### 4. Grounded Question Answering with Injection Defense
```swift
let (context, sources, citations) = try await client.ask(
    query: "What are the latest features in Swift Testing?"
)

// Send `context` directly to your on-device or host LLM
print("Grounding Context:\n\(context)")

for citation in citations {
    print("Citation \(citation.label): \(citation.title ?? "") (\(citation.url))")
}
```

### 5. Autonomous Multi-Round Research
```swift
let report = try await client.research(
    topic: "Apple Silicon Neural Engine architecture",
    options: .deep
)

print("Report Summary:\n\(report.summary)\n")
for section in report.sections {
    print("### \(section.heading)\n\(section.content)\n")
}
```

### 6. Embedding `ArchonChatView` in SwiftUI
```swift
import SwiftUI
import ArchonSearch

struct ContentView: View {
    @State private var client = ArchonSearchClient(configuration: .localFirst())

    var body: some View {
        ArchonChatView(client: client)
            .tint(.blue)
    }
}
```

---

## Concurrency, Security, & Error Handling

### Concurrency
All types strictly comply with Swift 6 Strict Concurrency. Long-running operations
support cooperative task cancellation (`Task.checkCancellation()`). All shared state
is actor-isolated (`ArchonSearchClient`, `RetrievalRouter`, `NativeReader`, `SearXNGClient`,
`Crawl4AIClient`, `SearchDatabase`), and views/view models are isolated to `@MainActor`.

### Security & Offline Enforcement
Network requests strictly respect `ArchonNetworkSecurity` zero-cloud and offline-mode
policies. If `ZeroCloudMode` is active or the device is offline, operations fail closed
with descriptive typed errors:

```swift
public enum SearchError: Error, LocalizedError, Sendable, Codable, Equatable {
    case offline
    case timeout(reason: String)
    case networkPolicy(reason: String)
    case searxng(reason: String)
    case crawl4ai(reason: String)
    case extraction(reason: String)
    case invalidURL(urlString: String)
    case localOnlyRequiresLocalSource
    case localOnlyRequiresStaticLocalCrawl
    case robotsDisallowed(urlString: String)
    case rateLimited(urlString: String, retryAfter: TimeInterval?)
    case extractionFailed(reason: String)
    case networkFailure(urlString: String, statusCode: Int)
    case initializationFailed(reason: String)
    case timeoutBudgetExceeded
    case noResultsFound
}
```
