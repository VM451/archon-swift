# ArchonSearch — Architecture & Data Flow

`ArchonSearch` 2.0 provides an offline-first, local-first web retrieval, grounding,
and autonomous research engine for Apple platforms (iOS 27+, macOS 27+, visionOS 27+).
It integrates provider-neutral meta-search, two-stage native extraction, remote
headless crawling, prompt-injection defense, citation verification, GRDB persistence,
and Liquid Glass conversational UI.

## Architecture Diagram

```mermaid
flowchart TD
    subgraph UI_Integration ["UI & Tool Integration"]
        UI["ArchonChatView<br/>Liquid Glass HIG · Light/Dark Parity"]
        Tools["FoundationModels.Tool Conformances<br/>WebSearchTool · ReadWebPageTool · ResearchTool"]
    end

    subgraph FacadeLayer ["Public Facade (§10)"]
        Client["ArchonSearchClient Actor<br/>.localFirst() · search() · read() · ask() · research()"]
    end

    UI --> Client
    Tools --> Client

    subgraph DiscoveryLayer ["Meta-Search Discovery"]
        SXClient["SearXNGClient Actor<br/>GET /search?format=json"]
        DockerSX[("Docker: SearXNG<br/>:8080")]
        SXClient --> DockerSX
    end

    subgraph RetrievalLayer ["Dual Retrieval Pipeline"]
        Router{"RetrievalRouter Actor<br/>5 Routing Policies"}

        subgraph RemotePath ["Remote Microservice"]
            C4Client["Crawl4AIClient Actor<br/>POST /crawl (REST API)"]
            DockerC4[("Docker: Crawl4AI<br/>:11235<br/>Headless JS & Markdown")]
            C4Client --> DockerC4
        end

        subgraph NativePath ["Native In-Process Extraction"]
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

        Router -->|.crawlerOnly / .preferCrawler| C4Client
        Router -->|.nativeOnly / .preferNative| Native
        Router -->|.automatic (healthy)| C4Client
        Router -->|.automatic (fallback)| Native
        C4Client --> Doc
    end

    subgraph ResearchPipeline ["Autonomous Research"]
        Coordinator["ResearchCoordinator Actor<br/>Multi-Round Query Formulation & Deduplication"]
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

    Client -->|search| SXClient
    Client -->|read| Router
    Client -->|research| Coordinator
    Client -->|ask| SXClient
    Client -->|persist / query| DB

    Coordinator --> SXClient
    Coordinator --> Router
    Coordinator --> CG

    Doc --> CB
    CB --> CG
    CG --> FinalAnswer["Grounded Response + Verified Citations"]
```

## System Subsystems

### 1. Public Facade (§10)
`ArchonSearchClient` is the solitary public actor entry point. Consumers interact
only with this facade, which coordinates meta-search, content extraction, grounding,
and persistence while keeping internal networking clients, parsers, and scrapers
encapsulated behind `internal` access boundaries.

### 2. Meta-Search Engine
`SearXNGClient` interfaces with a local or self-hosted SearXNG engine over HTTP JSON
(`GET /search?format=json`). Default deployment runs locally via Docker on port `8080`.
It normalizes diverse search providers into strongly typed `SearchResult` models without
third-party tracker leakage.

### 3. Dual Retrieval Router
`RetrievalRouter` arbitrates between remote headless crawling and native in-process
extraction across 5 operational policies:
- `.automatic`: Prefers Crawl4AI when healthy; gracefully falls back to NativeReader.
- `.preferCrawler`: Attempts Crawl4AI first; falls back to NativeReader on error.
- `.preferNative`: Attempts NativeReader first; escalates to Crawl4AI on failure.
- `.crawlerOnly`: Dispatches exclusively to Crawl4AI.
- `.nativeOnly`: Operates strictly in-process with zero network container dependencies.

#### Native Two-Stage Extraction
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
typed arguments for seamless on-device agent invocation.

### 7. Liquid Glass HIG User Interface
`ArchonChatView` presents an Apple-native conversational search experience built according
to the Liquid Glass HIG:
- Translucent materials (`.ultraThinMaterial`) and continuous corner curves (`RoundedRectangle`).
- Horizontal scrolling `CitationBadgeView` chips for rapid source inspection.
- Full Light/Dark appearance parity with semantic system colors.

### 8. Companion Docker Environment
A bundled `docker-compose.yml` provides a turn-key local-first container setup:
- `searxng/searxng:latest` on port `8080` (JSON search enabled).
- `unclecode/crawl4ai:latest` on port `11235` (headless Playwright/Chromium extraction).
