# ArchonSearch — Architecture & Data Flow

`ArchonSearch` 2.0 provides a 100% on-device, local-first web retrieval, grounding,
and autonomous research engine for Apple platforms (iOS 27+, macOS 27+, visionOS 27+).
On user devices, it operates entirely in the background with zero external servers,
zero Docker containers, and zero API keys required. It integrates provider-neutral
on-device search engines (`DuckDuckGoSearchEngine`), multi-engine fan-out
(`SearchEngineRegistry`), local keyword + neural reranking (`ResultReranker`,
`NaturalLanguageSimilarity`), query rewriting (`SearchQueryRewriter`), two-stage native
in-process extraction (`NativeReader`), prompt-injection defense, citation verification,
GRDB persistence, and Liquid Glass conversational UI. Docker companion microservices
(SearXNG, Crawl4AI) are supported as optional developer/proxy extensions.

## Architecture Diagram

```mermaid
flowchart TD
    subgraph UI_Integration ["UI & Tool Integration"]
        UI["ArchonChatView<br/>Liquid Glass HIG · Light/Dark Parity"]
        Tools["FoundationModels.Tool Conformances<br/>WebSearchTool · ReadWebPageTool · ResearchTool"]
    end

    subgraph FacadeLayer ["Public Facade (§10)"]
        Client["ArchonSearchClient Actor<br/>.onDevice() (Default) · .localFirst()<br/>search() · rankedSearch() · read() · ask() · research()"]
    end

    UI --> Client
    Tools --> Client

    subgraph DiscoveryLayer ["Search Engine Discovery (SearchEngine Protocol)"]
        direction TB
        subgraph PrimaryOnDeviceSearch ["Primary: 100% On-Device Engine"]
            DDG["DuckDuckGoSearchEngine Actor<br/>Direct HTML/Lite · URLSession + SwiftSoup<br/>Zero Docker · Zero Server · Zero API Keys"]
        end

        subgraph OptionalDockerSearch ["Optional Companion: Developer / Proxy"]
            SXClient["SearXNGClient Actor<br/>GET /search?format=json"]
            DockerSX[("Docker: SearXNG<br/>:8080")]
            SXClient --> DockerSX
        end

        Composite["CompositeSearchEngine Actor<br/>SearXNG with Transparent On-Device Fallback"]
        Composite -.-> SXClient
        Composite -.-> DDG
        Registry["SearchEngineRegistry Actor<br/>Named Adapter Fan-Out · URL Dedupe"]
        Registry -.-> DDG
        Registry -.-> SXClient
    end

    subgraph RankingLayer ["Local Ranking (No Network · No Model Download)"]
        Rewriter["SearchQueryRewriter<br/>Bounded Local Query Variants"]
        Reranker["ResultReranker<br/>Term Overlap + Freshness Decay<br/>Allow/Block Hosts · Max-Age"]
        Semantic["NaturalLanguageSimilarity<br/>On-Device NLEmbedding Vectors<br/>Bounded Semantic Boost"]
        Rewriter --> Reranker
        Semantic --> Reranker
    end

    subgraph RetrievalLayer ["Content Extraction Pipeline (RetrievalRouter)"]
        Router{"RetrievalRouter Actor<br/>.nativeOnly (Default) · .automatic · .preferNative"}

        subgraph NativePath ["Primary: Native In-Process Extraction"]
            Native["NativeReader Actor"]
            Stage1["Stage 1: SwiftSoupArticleExtractor<br/>Static Fetch & HTML Boilerplate Stripping"]
            Threshold{"Body &ge; 400 chars?"}
            Stage2["Stage 2: ReadabilityWebKitBridge (@MainActor)<br/>In-Process WKWebView + Mozilla Readability"]

            Native --> Stage1
            Stage1 --> Threshold
            Threshold -->|Yes| Doc["WebDocument<br/>Clean Text & Markdown"]
            Threshold -->|No: Escalate| Stage2
            Stage2 --> Doc
        end

        subgraph RemotePath ["Optional Companion: Microservice Crawler"]
            C4Client["Crawl4AIClient Actor<br/>POST /crawl (REST API)"]
            DockerC4[("Docker: Crawl4AI<br/>:11235<br/>Headless JS & Markdown")]
            C4Client --> DockerC4
        end

        Router -->|Default: .nativeOnly / .preferNative| Native
        Router -.->|Optional: .preferCrawler / .crawlerOnly| C4Client
        C4Client --> Doc
    end

    subgraph ResearchPipeline ["Autonomous Research"]
        Coordinator["ResearchCoordinator Actor<br/>Multi-Round Query Formulation & Deduplication<br/>Decoupled via any SearchEngine"]
    end

    subgraph GroundingSafety ["Grounding & Prompt Defense"]
        CB["ContextBuilder<br/>&lt;reference_data&gt; Isolation Enclosure<br/>Prompt Injection Sanitization"]
        CG["CitationGraph<br/>Citation Tag Parsing ([S1], [1], [S1/P2])<br/>Hallucination Verification & Renumbering"]
    end

    subgraph StorageLayer ["Persistence Layer"]
        DB[("SearchDatabase Actor<br/>GRDB SQLite + Auto-Migrations")]
        Tables["Conversations · Messages · Sessions<br/>Sources · Citations · TTL Web Cache"]
        DB --- Tables
    end

    Client -->|search (default)| DDG
    Client -->|search (companion/proxy)| Composite
    Client -->|rankedSearch| Reranker
    Client -->|read| Router
    Client -->|research| Coordinator
    Client -->|ask| DDG
    Client -->|persist / query| DB

    Coordinator --> DDG
    Coordinator --> Router
    Coordinator --> CG

    Doc --> CB
    CB --> CG
    CG --> FinalAnswer["Grounded Response + Verified Citations"]
```

## System Subsystems

### 1. Public Facade (§10)
`ArchonSearchClient` is the solitary public actor entry point conforming to §10 Facade.
By default, it initializes with `.onDevice()`, coordinating native search discovery,
in-process article extraction, injection defense, and SQLite storage with zero server dependencies.

### 2. Search Engine Discovery
The search discovery layer is unified behind the `SearchEngine` protocol:
- **`DuckDuckGoSearchEngine` (Primary On-Device)**: Queries DuckDuckGo HTML/Lite directly via
  `URLSession` and extracts search results using `SwiftSoup`. Operates 100% on-device with zero
  external proxies, zero Docker containers, and zero API keys.
- **`CompositeSearchEngine` (Adaptive Fallback)**: Transparently routes queries to a primary
  engine (such as SearXNG or custom proxy) and seamlessly falls back to on-device
  `DuckDuckGoSearchEngine` if the primary service is unreachable or errors.
- **`SearXNGClient` (Optional Companion)**: Interfaces with a self-hosted SearXNG meta-search
  instance over HTTP JSON (`GET /search?format=json`). Used in `.localFirst()` or server proxy setups.
- **`SearchEngineRegistry` (Multi-Engine Fan-Out)**: Host apps register named `SearchEngine`
  adapters (on-device plus explicit network adapters with host-owned credentials); `searchAll`
  fans out concurrently with per-engine failure isolation, deterministic URL dedupe, and
  cancellation checks.
- **`ResultReranker` + `SearchRankingOptions` (Local Rerank)**: Engine score plus query-term
  overlap, exponential freshness decay, `maxAge` filtering, and Goggles-style `allowHosts` /
  `blockHosts` scoping. Stable URL tiebreak; undated results keep relevance order.
- **`NaturalLanguageSimilarity` (On-Device Neural Rerank)**: Apple `NLEmbedding` sentence
  vectors behind the vendor-neutral `SemanticSimilarity` seam. No model download, no network;
  contributes a bounded clamped boost via `rankedSearch`, and soft-nils keep keyword behavior.
- **`SearchQueryRewriter` (Local Query Variants)**: Deterministic normalization plus bounded
  term-drop variants for parallel discovery fan-out. No model, no network.

### 3. Dual Retrieval Router & Native Extraction
`RetrievalRouter` arbitrates between native in-process extraction and optional companion crawling:
- `.nativeOnly` (Default for `.onDevice()`): Operates strictly in-process with zero network container dependencies.
- `.automatic`: Prefers Crawl4AI when available and healthy; gracefully falls back to `NativeReader`.
- `.preferNative`: Attempts `NativeReader` first; escalates to Crawl4AI on failure.
- `.preferCrawler`: Attempts Crawl4AI first; falls back to `NativeReader` on error.
- `.crawlerOnly`: Dispatches exclusively to Crawl4AI.

#### Native Two-Stage Extraction (Primary)
- **Stage 1 (`SwiftSoupArticleExtractor`)**: Performs lightweight, zero-overhead static HTML
  fetching and DOM parsing, stripping navigation, ads, cookies, and boilerplate.
- **Stage 2 (`ReadabilityWebKitBridge`)**: If Stage 1 yields fewer than 400 characters,
  execution escalates to an in-process `@MainActor` `WKWebView` evaluating Mozilla's
  Readability script to capture dynamic client-rendered JavaScript single-page applications.

### 4. Grounding & Anti-Injection Safety
- **`ContextBuilder`**: Encloses all external web content within `<reference_data>` XML
  boundaries accompanied by strict system instructions. It actively filters and sanitizes
  indirect prompt-injection vectors (e.g., instructions to ignore prior rules, system role
  imitations, and tokenizer delimiters) while enforcing strict token budgets.
- **`CitationGraph`**: Extracts attribution markers (`[S1]`, `[1]`, `[S1/P2]`) from generated
  text, maps each claim to retrieved source passages, verifies validity against actual
  evidence, strips hallucinated references, and resolves unified citation indices.

### 5. Structured Persistence
`SearchDatabase` wraps an actor-isolated SQLite database powered by GRDB with automatic
schema migrations. It manages:
- Conversational threads and chat message history (`conversations`, `messages`).
- Query session records with latency diagnostics (`search_sessions`).
- Provenance entities (`sources`, `citations`).
- TTL-based cached web documents (`cache_entries`) preventing duplicate network fetches.

### 6. Apple FoundationModels Tool Conformance
`WebSearchTool`, `ReadWebPageTool`, and `ResearchTool` conform to provider-neutral `Tool`
and Apple's native `FoundationModels.Tool` protocol, declaring `@FoundationModels.Generable`
typed arguments for seamless on-device agent invocation. Each tool defaults to on-device
engines (`DuckDuckGoSearchEngine`, `NativeReader`).

### 7. Liquid Glass HIG User Interface
`ArchonChatView` presents an Apple-native conversational search experience built according
to the Liquid Glass HIG:
- Translucent materials (`.ultraThinMaterial`) and continuous corner curves (`RoundedRectangle`).
- Horizontal scrolling `CitationBadgeView` chips for rapid source inspection.
- Full Light/Dark appearance parity with semantic system colors.

### 8. Optional Companion Docker Environment
A bundled `docker-compose.yml` provides an optional developer/server container setup:
- `searxng/searxng:latest` on port `8080` (JSON search enabled).
- `unclecode/crawl4ai:latest` on port `11235` (headless Playwright/Chromium extraction).

This environment is strictly an optional companion for developers testing self-hosted meta-search
or heavy server crawling, and is never required on end-user Apple devices.
