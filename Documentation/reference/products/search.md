# ArchonSearch Reference

`ArchonSearch` 2.0 is the current-information retrieval, webpage extraction,
grounding, and autonomous research product of the Archon SDK. It delivers a
local-first, privacy-preserving pipeline that connects Apple-native applications
(iOS 27+, macOS 27+, visionOS 27+) to local meta-search engines,
in-process article extractors, headless microservices, prompt injection defenses,
citation integrity verification, and Liquid Glass conversational UI.

## Architecture & On-Device Native Posture

ArchonSearch is designed to operate 100% on-device across Apple platforms (iOS 27+,
macOS 27+, visionOS 27+) in the background with **zero external servers, zero Docker
containers, and zero API keys**.

- **Search Engine Discovery**: Queries run directly on-device via `DuckDuckGoSearchEngine`,
  using native `URLSession` and `SwiftSoup` HTML parsing.
- **Article Extraction**: Extracted in-process via `NativeReader`, combining fast
  static `SwiftSoupArticleExtractor` DOM parsing with `@MainActor` `ReadabilityWebKitBridge`
  in an offscreen `WKWebView` when dynamic JavaScript rendering is required.
- **Structured Storage**: Persisted locally via `SearchDatabase` using GRDB SQLite.
- **Safety & Grounding**: Untrusted web text is isolated in `<reference_data>` envelopes
  via `ContextBuilder`, and model citations are verified via `CitationGraph`.

### Optional Developer Companion Infrastructure (Docker)

For developer workstations, self-hosted proxy environments, or enterprise headless
crawling, an optional companion setup is provided via the root `docker-compose.yml`:

```bash
docker compose up -d
```

| Service | Image | Local Port | Protocol / Purpose |
| --- | --- | --- | --- |
| `searxng` | `searxng/searxng:latest` | `8080` | Optional HTTP JSON meta-search (`/search?format=json`) aggregating multiple search providers. |
| `crawl4ai` | `unclecode/crawl4ai:latest` | `11235` | Optional REST microservice (`/crawl`) for headless Playwright/Chromium extraction and Markdown generation. |

This container environment is strictly optional. If companion containers are absent,
unreachable, or unconfigured, ArchonSearch operates entirely on-device via
`DuckDuckGoSearchEngine` and `NativeReader`.

---

## Core Types Reference

### 1. `ArchonSearchClient`
The high-level public actor facade conforming to the §10 Facade pattern. It hides
internal search engines, parsers, and repositories behind a unified interface. By
default, it operates 100% on-device without contacting any local or remote servers.

```swift
public actor ArchonSearchClient: Sendable {
    public let configuration: ArchonSearchConfiguration

    public init(
        configuration: ArchonSearchConfiguration = .onDevice(),
        database: SearchDatabase? = nil
    )

    public func search(_ query: String, categories: [String]? = nil, page: Int = 1) async throws -> [SearchResult]
    public func rankedSearch(_ query: String, categories: [String]? = nil, page: Int = 1, options: SearchRankingOptions = SearchRankingOptions(), similarity: (any SemanticSimilarity)? = nil, semanticWeight: Double = 0.4) async throws -> [SearchResult]
    public func read(url: URL, options: ReaderOptions = ReaderOptions()) async throws -> WebDocument
    public func ask(query: String) async throws -> (context: String, sources: [Source], citations: [Citation])
    public func ask(_ query: String) async throws -> SearchAnswer
    public func research(topic: String, options: ResearchOptions = ResearchOptions()) async throws -> ResearchReport
    public func checkHealth() async -> (searxngHealthy: Bool, crawlerHealthy: Bool)
}
```

- `search(_:categories:page:)`: Dispatches queries to the configured `SearchEngine` (`DuckDuckGoSearchEngine` by default) and returns `[SearchResult]`.
- `rankedSearch(_:categories:page:options:)`: Applies the local `ResultReranker` (term overlap + freshness decay + host allow/block scoping + max-age filter) with no network or model. The optional `embedding:` parameter (or `SearchRankingOptions.embedding`) opts into the Apple-API embedding blend; `rankedSearchWithDiagnostics` additionally reports `SearchDiagnostics.usedSemanticRerank`.
- `read(url:options:)`: Extracts clean text and Markdown from a URL using `RetrievalRouter` (`NativeReader` by default).
- `ask(query:)` / `ask(_:)`: Executes search, extracts source pages, encapsulates content inside `<reference_data>`, and verifies citations (returning tuple or `SearchAnswer`).
- `research(topic:options:)`: Executes autonomous multi-round iterative research.
- `checkHealth()`: Reports availability status of companion SearXNG and Crawl4AI endpoints.

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

    /// Default 100% on-device configuration: native-only extraction, direct DuckDuckGo search.
    public static func onDevice() -> ArchonSearchConfiguration

    /// Optional local-first configuration targeting local Docker companion containers.
    public static func localFirst(
        searxngURL: URL? = URL(string: "http://localhost:8080"),
        crawl4aiURL: URL? = URL(string: "http://localhost:11235")
    ) -> ArchonSearchConfiguration

    /// Explicit alias for Docker companion configuration.
    public static func dockerCompanion(
        searxngURL: URL? = URL(string: "http://localhost:8080"),
        crawl4aiURL: URL? = URL(string: "http://localhost:11235")
    ) -> ArchonSearchConfiguration
}
```

#### Settings Groups
- `SearchEngineSettings`: `searxngURL`, `enabledEngines: [String]`, `categories: [String]`, `language: String`, `safeSearch: Int`.
- `CrawlerSettings`: `crawl4aiURL`, `maxDepth: Int`, `maxConcurrentFetches: Int`, `userAgent: String?`, `respectRobotsTxt: Bool`, `renderJavaScript: Bool`.
- `TimeoutSettings`: `searchTimeout: TimeInterval` (default `8.0s` on-device, `10.0s` companion), `fetchTimeout: TimeInterval` (default `12.0s` on-device, `15.0s` companion), `totalLatencyBudget: TimeInterval?`.
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

### 4. `SearchEngine` Protocol & Implementations

ArchonSearch abstracts search provider discovery behind the sendable `SearchEngine` protocol, enabling seamless on-device execution alongside optional proxy or companion backends:

```swift
public protocol SearchEngine: Sendable {
    func search(_ query: String, categories: [String]?, page: Int) async throws -> [SearchResult]
    func checkHealth() async -> Bool
}

extension SearchEngine {
    public func search(_ query: String) async throws -> [SearchResult]
}
```

#### `DuckDuckGoSearchEngine` (Primary On-Device)
An actor conforming to `SearchEngine` that queries DuckDuckGo HTML/Lite directly via native `URLSession` and extracts clean `[SearchResult]` items using `SwiftSoup` DOM parsing (with regex fallback). Operates 100% on-device in the background with **zero external servers, zero Docker containers, and zero API keys**.

```swift
public actor DuckDuckGoSearchEngine: SearchEngine {
    public init(session: URLSession = .shared)

    public func search(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1
    ) async throws -> [SearchResult]

    public func checkHealth() async -> Bool
}
```

#### `CompositeSearchEngine` (Adaptive Fallback)
An actor conforming to `SearchEngine` that holds an optional primary engine (e.g., SearXNG or custom proxy) and a reliable fallback engine (defaulting to `DuckDuckGoSearchEngine`). If the primary engine is nil, fails health checks, or throws an error during search, it transparently executes against the on-device fallback.

```swift
public actor CompositeSearchEngine: SearchEngine {
    public let primary: (any SearchEngine)?
    public let fallback: any SearchEngine

    public init(
        primary: (any SearchEngine)? = nil,
        fallback: any SearchEngine = DuckDuckGoSearchEngine()
    )

    public func search(
        _ query: String,
        categories: [String]? = nil,
        page: Int = 1
    ) async throws -> [SearchResult]

    public func checkHealth() async -> Bool
}
```

#### `SearchEngineRegistry` (Multi-Engine Fan-Out)
Actor registry for named `SearchEngine` adapters. Host apps register on-device and explicit network adapters (SearXNG, future Brave/Tavily/Exa adapters with host-owned credentials); `searchAll` fans out concurrently with per-engine failure isolation, deterministic URL dedupe, and cancellation checks.

#### `ResultReranker` + `SearchRankingOptions` (Local Rerank)
Dependency-free value types combining engine score, query-term overlap, exponential freshness decay (`freshnessHalfLife`), `maxAge` filtering, and Goggles-style `allowHosts`/`blockHosts` scoping. Sorting is stable by URL; undated results keep relevance order.

#### `SemanticSimilarity` + `NaturalLanguageSimilarity` (On-Device Neural Rerank)
Vendor-neutral meaning-overlap seam with an Apple `NLEmbedding` sentence-vector implementation: no model download, no network, no new dependency. `ResultReranker` adds a bounded boost (`semanticWeight`, clamped 0...1); `nil` similarity keeps keyword behavior. Host apps can inject their own scorers. `NaturalLanguageSimilarity(languageCode:)` accepts BCP-47 codes (region subtags stripped); unknown codes report `isAvailable == false` and callers fall back to keyword ranking.

#### `EmbeddingRerankOptions` (Opt-In Embedding Blend)
```swift
public struct EmbeddingRerankOptions: Sendable, Codable, Equatable {
    public var enabled: Bool            // default false: strictly opt-in
    public var weight: Double           // clamped 0...1 at use time
    public var language: String         // BCP-47, default "en"
    public var maxCharsPerResult: Int   // bound 1...2000, default 500
}
```
Carried by `SearchRankingOptions.embedding` or passed directly to `rankedSearch(embedding:)` / `ResultReranker.rank(embedding:)`. Disabled, `nil`, zero-weight, or unavailable-embedding configurations return keyword-identical order; `rankWithEmbedding` / `rankedSearchWithDiagnostics` report whether any semantic score applied via `usedSemanticRerank`. Default rank order never changes when embedding is off.

#### `AnswerQualityEval` (Deterministic Fixture Eval)
Pure, in-process answer-quality scoring over `AnswerQualityFixture` values (query, retrieved results, answer, expected citations, abstention flag): citation precision/recall, fail-closed hallucination count (unknown sources *and* passages such as `[S1/P9]`), groundedness, abstention correctness, and injection neutralization (`[FILTERED_INJECTION]` + intact `<reference_data>` envelope). Bounded to `maxFixtures` (default 200, hard cap 200); empty input throws `SearchError.noResultsFound`; the aggregate is the per-fixture mean. Fixtures live in `Tests/ArchonSearchTests/Fixtures/answer-quality.json`. No network, no model; every score carries a `deterministic` self-check flag.

#### `SearchQueryRewriter` (Local Query Variants)
Deterministic normalization plus bounded term-drop variants for parallel discovery fan-out. No model, no network.

#### `SearXNGClient` (Optional Companion)
Actor conforming to `SearchEngine` managing HTTP JSON queries against a self-hosted SearXNG instance without third-party trackers. Used in Docker companion or server proxy configurations.

```swift
public actor SearXNGClient: SearchEngine, Sendable {
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

### 13. `FrontierQueueActor` Scheduling (Politeness-Aware Crawl Priority)

`FrontierQueueActor` is the SwiftData-backed crawl frontier. Until configured,
dequeue uses legacy behavior (global priority order, sleeping politeness
waits). `configureScheduling(_:)` opts into politeness-aware scheduling:

```swift
public struct CrawlScheduleOptions: Sendable, Codable, Equatable {
    public var maxQueuedPerHost: Int  // default 100, >= 1
    public var maxHostsInFlight: Int  // default 4, >= 1
    public var maxRetries: Int        // default 3, >= 1
    public var baseDelay: TimeInterval   // default 1s, >= 0
    public var maxDelay: TimeInterval    // default 30s
    public var backoffCap: TimeInterval  // default 300s, >= 1
    public var depthPenalty: Double   // default 0.5, >= 0
    public var failurePenalty: Double // default 1.0, >= 0
}

public enum CrawlHostOutcome: Sendable, Equatable {
    case success
    case rateLimited(retryAfter: TimeInterval?)
    case serverError
}
```

Semantics and bounds:

- Within each host, nodes dequeue by effective score
  `priority - depth x depthPenalty - failures x failurePenalty`
  (ties: earliest added, then lowest URL). `CrawlNode` carries additive,
  defaulted `depth` and `failureCount`; the depth-aware
  `enqueue(urls:priorities:parentURLString:depth:)` overload seeds depth.
- Hosts serve round-robin: no host dequeues twice until every ready host has
  served once (ties broken alphabetically for determinism).
- Hosts in backoff or inside their robots crawl-delay are *skipped*, never
  slept on: dequeue returns the next ready host's URL, or `nil` when nothing
  is currently servable.
- `reportHostOutcome(host:outcome:)` applies outcomes: success clears backoff
  and failure counts; 429 backs off by the server `Retry-After` (clamped to
  `backoffCap`); 5xx backs off exponentially from `baseDelay`, capped by
  `maxDelay` and `backoffCap`. `retryCount >= maxRetries` marks nodes
  `.failed` (also honored by `markFailed`).
- New hosts are withheld while `maxHostsInFlight` distinct hosts are
  crawling; enqueue keeps at most `maxQueuedPerHost` pending nodes per host,
  dropping lowest priority deterministically.
- Dequeue is cancellation-checked (`Task.checkCancellation()`); cancellation
  leaves nodes pending so the crawl recovers on retry.

### 14. `ArchonChatView` & UI Components
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

// 100% on-device configuration (default): zero Docker, zero server, zero API keys
let client = ArchonSearchClient() // or ArchonSearchClient(configuration: .onDevice())
```

#### Optional Docker Companion Initialization
```swift
// Explicitly opt into local companion Docker services (SearXNG :8080, Crawl4AI :11235)
let companionClient = ArchonSearchClient(configuration: .localFirst())

// Health check verifying local container connectivity
let (searxngOk, crawlerOk) = await companionClient.checkHealth()
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
    options: ReaderOptions(mode: .nativeOnly, timeout: 15.0)
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
    // 100% on-device execution with zero server or container dependencies
    @State private var client = ArchonSearchClient()

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
