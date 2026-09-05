# Competitor comparison and scorecard

This document is the readable comparison view for Archon's living competitor
registry. It explains what each reference product is strong at, scores the
relevant aspects, and translates the result into a local-first Archon decision.

**Review snapshot:** 2026-09-05<br>
**Canonical evidence:** this comparison and its linked official sources<br>
**Canonical quality gates:** [`validate a release`](../how-to/validate-a-release.md)

## Executive summary

The scores are decision aids, not market-share rankings. A cloud product can
score highly for a signature workflow and still fail Archon's local-native
qualification gate. Archon therefore keeps two questions separate:

1. **Capability score:** How strong is the documented feature outcome?
2. **Engineering score:** How suitable is the outcome for a native, local,
   in-process Swift SDK?

| Category | Strongest documented outcome | Highest capability average | Local-native conclusion | Archon action |
| --- | --- | :---: | --- | --- |
| Memory | Zep's temporal truth and Mem0's automatic memory lifecycle | 3.4 / 5 | Cloud services do not qualify as local replacements | Build Archon semantics; adapt qualifying indexes only |
| Agent orchestration | LangGraph recovery and OpenAI Agents SDK tools/handoffs | 3.7 / 5 | Framework runtimes are not native Swift replacements | Adapt patterns into ArchonAgent |
| Search and research | Firecrawl extraction and Tavily/Exa agent-ready research | 3.1 / 5 | Web search is network-dependent unless using a local corpus | Build local orchestration; add explicit adapters |
| Sandbox and browser action | E2B/Deno isolation and Stagehand semantic browser actions | 3.3 / 5 | Remote VMs/browsers are not local in-process Swift | Build local safety/semantic boundaries; adapt remote services |
| Models and runtimes | Foundation Models/Core ML local Apple execution | 4.6 / 5 | Apple-native paths qualify; others qualify only by runtime | Reuse Apple APIs; adapt lifecycle and artifacts |
| Protocols | MCP's interoperable tools, resources, and prompts | 4.3 / 5 | The SDK is local Swift; connected servers may be remote | Adapt the official SDK; retain Archon policy |

## How to read the scores

### Capability scale

Every aspect score is from 0 to 5. It measures the capability represented by
the row, not the size, popularity, or revenue of the vendor.

| Score | Meaning |
| :---: | --- |
| 0 | No meaningful support, or the capability is outside the product's scope |
| 1 | Experimental, indirect, or only a weak adjacent pattern |
| 2 | Documented capability with limited evidence or important restrictions |
| 3 | Useful, meaningful support with a clear limitation |
| 4 | Strong, mature capability with a well-defined workflow |
| 5 | Signature capability with broad evidence and clear product identity |

`Capability average` is the arithmetic mean of the aspect scores in that
category. It is useful for comparing feature coverage, but it does not approve
an Archon dependency.

### Engineering score

The primary product score is engineering readiness. It deliberately excludes
user-pull evidence so market enthusiasm cannot inflate a technical score:

```text
engineering = (differentiation * 0.2667)
             + (localFeasibility * 0.2667)
             + (qualitySafety * 0.20)
             + (maintainability * 0.1333)
             + (strategicFit * 0.1333)

engineeringScore = engineering * 20
```

| Dimension | Weight | What is being scored |
| --- | :---: | --- |
| Differentiation | 26.67% | How strongly the capability identifies the product |
| Local feasibility | 26.67% | Apple-device, in-process, native Swift/SwiftPM feasibility |
| Quality and safety | 20% | Typed failures, bounded resources, privacy, recovery, and safety evidence |
| Maintainability | 13.33% | API clarity, dependency health, license, platform support, and ownership |
| Archon strategic fit | 13.33% | Fit with Archon's local-first, vendor-neutral architecture |

User pull is reported separately as evidence (`High`, `Medium`, `Low`, or
`Unknown`). It is never invented, and it never raises the engineering score.

For historical comparison only, detailed competitor tables may also show a
market-aware `Overall / 100` value that includes user pull. The product
readiness table uses `Engineering / 100` and is the authoritative release
score.

The numeric score is provisional when independent user-pull evidence or
consuming-device evidence is incomplete. A provisional score never overrides a
failed local, security, recovery, license, or platform gate.

### Engineering-score bands

| Score | Interpretation | Default Archon posture |
| :---: | --- | --- |
| 80–100 | Strong local or strategic reference | Consider `REUSE`/`ADAPT` only after gates |
| 60–79 | Strong pattern or adapter opportunity | `ADAPT` or focused `BUILD` |
| 40–59 | Useful inspiration with material limitations | `INSPIRATION`, optional adapter, or `PENDING` |
| 0–39 | Weak fit or insufficient evidence | `PENDING`; do not adopt |

### Qualification symbols

| Symbol | Meaning |
| :---: | --- |
| ✅ | Qualifies for the specific local/native criterion |
| ⚠️ | Partial, mixed, hosted, optional, or adapter-dependent |
| ❌ | Does not qualify for the criterion |

## 1. Memory systems

Source records: the memory comparison in this document.

### What users select these products for

| Product | Signature outcome | Archon feature to extract |
| --- | --- | --- |
| [Mem0](https://docs.mem0.ai/features/contextual-add) | Automatic extraction, deduplication, contradiction-aware updates, and hybrid retrieval | Memory decisions should be useful without requiring manual fact authoring |
| [Supermemory](https://docs.supermemory.ai/memory-api/introduction) | Broad ingestion, connectors, multimodality, filtering, reranking, and profile synthesis | Memory should unify many sources with provenance and a useful profile |
| [Zep](https://help.getzep.com/v2/concepts) | Temporal knowledge graph and fact invalidation | Memory must represent what was true, when it was true, and what superseded it |
| [Letta](https://docs.letta.com/api/typescript) | Self-editing working-memory blocks and hierarchical context | Agents need explicit, bounded working memory separate from durable history |
| [CrewAI Memory](https://github.com/crewAIInc/crewAI/blob/main/docs/v1.15.12/en/concepts/memory.mdx) | Scoped semantic, recency, and importance recall | Multi-agent memory needs deterministic scopes and composite retrieval |

### Capability scores — memory aspects

| Competitor | Extraction | Dedup / conflict | Temporal truth | Working memory | Hybrid retrieval | Local Swift | Audit / export | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Mem0 | 5 | 5 | 3 | 2 | 5 | 0 | 3 | **3.3** | ❌ |
| Supermemory | 5 | 4 | 2 | 2 | 4 | 0 | 3 | **2.9** | ❌ |
| Zep | 4 | 4 | 5 | 3 | 4 | 0 | 4 | **3.4** | ❌ |
| Letta | 4 | 3 | 3 | 5 | 3 | 0 | 4 | **3.1** | ❌ |
| CrewAI Memory | 3 | 3 | 2 | 3 | 4 | 0 | 3 | **2.6** | ❌ |
| ArchonMemory contract | 5 | 5 | 5 | 5 | 5 | 5 | 5 | **5.0** | ✅ |

### Market-aware comparator scores — memory

| Competitor | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| Mem0 | 2 | 5 | 0 | 4 | 4 | 2 | **54** | ADAPT + BUILD semantics |
| Supermemory | 2 | 5 | 0 | 3 | 4 | 2 | **51** | ADAPT + BUILD ingestion/profile |
| Zep | 2 | 5 | 0 | 4 | 4 | 2 | **54** | ADAPT + BUILD temporal semantics |
| Letta | 2 | 5 | 0 | 3 | 3 | 3 | **51** | ADAPT working-memory pattern |
| CrewAI Memory | 2 | 4 | 0 | 3 | 3 | 2 | **45** | INSPIRATION |
| ArchonMemory contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | BUILD semantics; release gates open |

### Memory implementation decision

| Keep from the market | Archon implementation boundary | Required proof |
| --- | --- | --- |
| Extraction and `ADD/UPDATE/DELETE/NO_CHANGE` decisions | `MemoryExtractor` plus durable `MemoryItem` history | Contradiction and temporal invalidation tests |
| Temporal facts and supersession | `validFrom`, `validTo`, `supersededById`, and `GraphStore` | Deterministic temporal queries and migration |
| Working-memory blocks | `CoreMemoryBlock` and `CoreMemoryManager` | Scope isolation, limits, consent, and reopen behavior |
| Hybrid retrieval | FTS5, dense vectors, filters, recency, and importance | Recall@10 ≥ 0.99, p95, memory ceiling, update/delete |
| Profile synthesis and provenance | Document ingestion plus `ArchonContext` contributors | Export, audit, source provenance, and deletion correctness |

## 2. Agent orchestration

Source records: the agent comparison in this document.

### What users select these products for

| Product | Signature outcome | Archon feature to extract |
| --- | --- | --- |
| [LangGraph](https://docs.langchain.com/oss/python/langgraph/persistence) | Durable graph checkpoints, interrupts, recovery, state inspection, and time travel | Agents must resume, fork, and replay without losing state |
| [CrewAI](https://docs.crewai.com/index) | Crews, Flows, memory, guardrails, and observability | Role-based agents should grow into inspectable production flows |
| [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/agents/) | Tools, handoffs, sessions, guardrails, structured outputs, and tracing | Delegation and side effects need typed boundaries and approvals |
| [LlamaIndex](https://www.llamaindex.ai/) | Data connectors, retrieval composition, workflows, and evaluation | Agent workflows need source-aware retrieval and evaluation |
| [PydanticAI](https://ai.pydantic.dev/) | Schema-first tools and structured outputs | Tool contracts should be easy to validate and test |

### Capability scores — agent aspects

| Competitor | Graph / state | Tools / handoffs | Guardrails / schema | Streaming / tracing | Local Swift | Evaluation | Recovery evidence | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| LangGraph | 5 | 4 | 4 | 4 | 0 | 4 | 5 | **3.7** | ❌ |
| CrewAI | 4 | 5 | 3 | 4 | 0 | 4 | 3 | **3.3** | ❌ |
| OpenAI Agents SDK | 4 | 5 | 5 | 4 | 0 | 4 | 4 | **3.7** | ❌ |
| LlamaIndex | 4 | 3 | 3 | 3 | 0 | 4 | 3 | **2.9** | ❌ |
| PydanticAI | 3 | 4 | 5 | 3 | 0 | 3 | 4 | **3.1** | ❌ |
| ArchonAgent contract | 5 | 5 | 5 | 5 | 5 | 4 | 4 | **4.7** | ✅ |

### Market-aware comparator scores — agents

| Competitor | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| LangGraph | 2 | 5 | 0 | 4 | 4 | 4 | **58** | ADAPT orchestration patterns |
| CrewAI | 2 | 5 | 0 | 3 | 3 | 3 | **51** | ADAPT workflow patterns |
| OpenAI Agents SDK | 2 | 5 | 0 | 4 | 5 | 4 | **60** | ADAPT tools/handoffs |
| LlamaIndex | 2 | 5 | 0 | 3 | 4 | 3 | **53** | INSPIRATION for retrieval composition |
| PydanticAI | 2 | 4 | 0 | 4 | 4 | 4 | **54** | ADAPT schema-first contracts |
| ArchonAgent contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | BUILD/ADAPT; recovery gates open |

### Agent implementation decision

| Keep from the market | Archon implementation boundary | Required proof |
| --- | --- | --- |
| Durable checkpoints and time travel | `Graph`, `StateCheckpointer`, `GraphInterrupt`, replay, and fork contracts | Crash recovery, idempotence, deterministic replay |
| Tools, handoffs, and agents-as-tools | Typed `ToolDispatcher`, subgraphs, handoffs, and authorization | Approval, duplicate-side-effect, and cancellation tests |
| Guardrails and structured outputs | `Codable` schemas, typed errors, refusal, and policy gates | Invalid schema, refusal, retry, and trace-redaction tests |
| Streaming and observability | `AsyncSequence` streams, events, and tracing | Backpressure, cancellation, privacy, and recovery |

## 3. Search and research

Source records: the search comparison in this document.

### What users select these products for

| Product | Signature outcome | Archon feature to extract |
| --- | --- | --- |
| [Tavily](https://docs.tavily.com/welcome) | Search, extract, crawl, map, reranking, and research context | Research should produce compact, agent-ready evidence |
| [Exa](https://exa.ai/docs/reference/search) | Neural search, contents, highlights, freshness, and structured search | Semantic relevance and model-ready passages matter |
| [Firecrawl](https://docs.firecrawl.dev/api-reference/endpoint/scrape) | Scrape, crawl, map, structured extraction, and browser interaction | Difficult websites need bounded extraction workflows |
| [Brave Search](https://brave.com/search/api/) | Independent index, citations, and controllable filtering | Source independence and result controls are valuable |
| [Perplexity](https://docs.perplexity.ai/) | Conversational answer synthesis with citations | Claims and evidence should arrive together |
| [ChatGPT Search](https://help.openai.com/en/articles/9237897-chatgpt-search) | Conversational web research and follow-up context | Users should be able to research naturally |
| [SerpAPI](https://serpapi.com/) | Normalized results across engines and verticals | Provider changes should not require parser rewrites |
| [SearXNG](https://docs.searxng.org/) / [Perplexica](https://github.com/ItzCrazyKns/Perplexica) | Self-hosted metasearch and customizable research | Source and deployment control should be explicit |
| [TinyFish](https://docs.tinyfish.ai/) | Goal-oriented browser research and actions | Outcome-oriented browser work needs approvals and postconditions |

### Capability scores — search aspects

| Competitor | Discovery / ranking | Crawl / extract | Freshness / structure | Citations / provenance | Offline local | Network control | Browser action | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Tavily | 5 | 4 | 4 | 4 | 0 | 2 | 2 | **3.0** | ❌ |
| Exa | 5 | 2 | 5 | 4 | 0 | 2 | 1 | **2.7** | ❌ |
| Firecrawl | 4 | 5 | 4 | 3 | 0 | 2 | 4 | **3.1** | ❌ |
| Brave Search | 4 | 1 | 4 | 4 | 0 | 2 | 1 | **2.3** | ❌ |
| Perplexity | 4 | 2 | 5 | 5 | 0 | 1 | 1 | **2.6** | ❌ |
| ChatGPT Search | 4 | 1 | 4 | 4 | 0 | 1 | 1 | **2.1** | ❌ |
| SerpAPI | 5 | 1 | 4 | 3 | 0 | 2 | 1 | **2.3** | ❌ |
| SearXNG | 4 | 2 | 3 | 3 | 1 | 4 | 1 | **2.6** | ⚠️ |
| Perplexica | 3 | 2 | 3 | 3 | 1 | 3 | 1 | **2.3** | ⚠️ |
| TinyFish | 3 | 3 | 2 | 2 | 0 | 1 | 5 | **2.3** | ❌ |
| ArchonSearch contract | 4 | 4 | 4 | 5 | 5 | 5 | 3 | **4.3** | ✅ |

### Market-aware comparator scores — search

| Competitor | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| Tavily | 2 | 5 | 0 | 4 | 4 | 4 | **58** | ADAPT cloud adapter; BUILD local path |
| Exa | 2 | 5 | 0 | 4 | 4 | 3 | **56** | ADAPT ranking/content contract |
| Firecrawl | 2 | 5 | 0 | 4 | 4 | 3 | **56** | ADAPT extraction contract |
| Brave Search | 2 | 4 | 0 | 4 | 4 | 3 | **52** | ADAPT provider behind network policy |
| Perplexity | 2 | 5 | 0 | 4 | 4 | 3 | **56** | INSPIRATION + ADAPT citations |
| ChatGPT Search | 2 | 5 | 0 | 4 | 5 | 2 | **56** | INSPIRATION |
| SerpAPI | 2 | 4 | 0 | 4 | 4 | 3 | **52** | ADAPT normalized provider |
| SearXNG | 2 | 4 | 1 | 3 | 3 | 4 | **53** | INSPIRATION / remote adapter |
| Perplexica | 2 | 4 | 1 | 2 | 2 | 3 | **46** | INSPIRATION; keep server explicit |
| TinyFish | 2 | 5 | 0 | 3 | 3 | 3 | **51** | ADAPT remote browser only |
| ArchonSearch contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | BUILD local orchestrator; gates open |

### Search implementation decision

| Keep from the market | Archon implementation boundary | Required proof |
| --- | --- | --- |
| Query rewriting and reranking | Provider-neutral query and ranking contracts | Deterministic ranking and citation tests |
| Crawl, map, and extract | Bounded local WebKit/URLSession orchestration plus adapters | Robots, limits, prompt-injection isolation, cleanup |
| Freshness and structured output | `SearchResult`, source graph, extraction schema, and timestamps | Freshness policy and schema failure tests |
| Citations and claims | Claim-to-source references with network metadata | Verifiable source URLs and abstention |
| Offline research | Local corpus provider under `localOnly` | Network-denied tests prove no remote attempt |

## 4. Sandbox, browser, and computer-use systems

Source records: the sandbox and Computer Use comparisons in this document.

### What users select these products for

| Product | Signature outcome | Archon feature to extract |
| --- | --- | --- |
| [E2B](https://e2b.dev/) | Disposable Firecracker microVM code execution | Strong isolation behind a convenient agent API |
| [Modal](https://modal.com/docs/guide/sandboxes) | Secure containers, snapshots, forks, and lifecycle | Reproducible execution state and fast lifecycle control |
| [Daytona](https://www.daytona.io/docs/sandboxes) | Managed development workspaces | Repeatable agent workspaces with cleanup |
| [Deno Sandbox](https://docs.deno.com/sandbox/security/) | Ephemeral VM, network policy, secret redaction, cleanup, and audit | Security defaults for untrusted code |
| [Browserbase](https://docs.browserbase.com/) | Hosted browser sessions and operational tooling | Reliable browser state and session operations |
| [Stagehand](https://docs.stagehand.dev/v2/first-steps/quickstart) | `observe`, `act`, and `extract` | Semantic browser actions over brittle selectors |
| [OpenAI Computer Use](https://developers.openai.com/api/docs/guides/tools-computer-use) | Screenshot-driven click/type/scroll/key actions | Fallback control when semantic host information is unavailable |
| [Anthropic Computer Use](https://platform.claude.com/docs/en/agents-and-tools/computer-use-tool) | Client-executed screenshot and input controls | Keep side effects in the host client with approvals |
| [TinyFish](https://docs.tinyfish.ai/) | Goal-oriented browser workflows | Outcome-based navigation with postconditions |

### Capability scores — sandbox and action aspects

| Competitor | Isolation | Workspace / lifecycle | Network / secrets | Browser action | Local Swift | Audit / recovery | Semantic action | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| E2B | 5 | 4 | 5 | 1 | 0 | 4 | 1 | **2.9** | ❌ |
| Modal | 4 | 5 | 4 | 0 | 0 | 4 | 0 | **2.4** | ❌ |
| Daytona | 3 | 4 | 3 | 0 | 0 | 3 | 0 | **1.9** | ❌ |
| Deno Sandbox | 5 | 4 | 5 | 0 | 0 | 5 | 0 | **2.7** | ❌ |
| Browserbase | 3 | 4 | 3 | 5 | 0 | 4 | 4 | **3.3** | ❌ |
| Stagehand | 1 | 3 | 2 | 5 | 0 | 3 | 5 | **2.7** | ❌ |
| OpenAI Computer Use | 1 | 2 | 2 | 5 | 0 | 3 | 4 | **2.4** | ❌ |
| Anthropic Computer Use | 1 | 2 | 3 | 5 | 0 | 4 | 4 | **2.7** | ❌ |
| TinyFish | 1 | 3 | 2 | 5 | 0 | 2 | 5 | **2.6** | ❌ |
| ArchonSandbox / Computer Use contract | 3 | 4 | 4 | 3 | 5 | 3 | 5 | **3.9** | ✅ |

### Market-aware comparator scores — sandbox and action

| Competitor | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| E2B | 2 | 5 | 0 | 5 | 4 | 3 | **59** | ADAPT remote microVM boundary |
| Modal | 2 | 5 | 0 | 5 | 4 | 3 | **59** | ADAPT remote lifecycle concepts |
| Daytona | 2 | 4 | 0 | 3 | 3 | 2 | **45** | INSPIRATION |
| Deno Sandbox | 2 | 5 | 0 | 5 | 4 | 4 | **61** | ADAPT safety policy patterns |
| Browserbase | 2 | 4 | 0 | 4 | 3 | 2 | **48** | ADAPT remote browser only |
| Stagehand | 2 | 5 | 0 | 3 | 3 | 4 | **53** | ADAPT observe/act/extract semantics |
| OpenAI Computer Use | 2 | 5 | 0 | 3 | 4 | 3 | **53** | ADAPT screenshot fallback |
| Anthropic Computer Use | 2 | 5 | 0 | 4 | 4 | 3 | **56** | ADAPT client-side approval pattern |
| TinyFish | 2 | 5 | 0 | 3 | 3 | 3 | **51** | ADAPT remote browser only |
| ArchonSandbox / Computer Use contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | BUILD semantic local boundary; gates open |

### Sandbox and action implementation decision

| Keep from the market | Archon implementation boundary | Required proof |
| --- | --- | --- |
| Deny-by-default execution | `SandboxConfiguration`, capability policy, CSP, quotas, and typed failures | Path traversal, CSP, blocked network, quota, and cleanup tests |
| Snapshots and workspace lifecycle | `SandboxWorkspace` plus explicit remote adapter isolation | Atomic snapshots, teardown, secrets, and recovery |
| Observe/act/extract | Semantic observations, DOM/App Intents/accessibility actions, and extraction | Stale-state, postcondition, and provenance tests |
| Screenshot fallback | Explicitly approved screenshot/coordinate provider | Risk approval, privacy, cancellation, and audit |

## 5. Models and local runtimes

Source records: the models and runtimes comparison in this document.

### What users select these products for

| Product | Signature outcome | Archon feature to extract |
| --- | --- | --- |
| [Foundation Models](https://developer.apple.com/documentation/FoundationModels) | Apple on-device generation, guided output, and tool calling | Reuse the supported Apple model runtime directly |
| [Core ML](https://developer.apple.com/documentation/CoreML) | Hardware-accelerated local inference and compiled artifacts | Reuse the runtime; build artifact and lifecycle contracts |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | Apple Silicon local tensor/runtime path for open models | Adapt the local runtime without leaking MLX types |
| [Hugging Face Swift](https://github.com/huggingface/swift-transformers) | Tokenizers, Hub metadata/downloads, and model ecosystem tooling | Adapt catalog/artifact tooling; validate runnable formats explicitly |
| [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) | Provider-neutral model/session abstraction | Compare narrowly against `LLMProvider` |
| [Conduit](https://github.com/christopherkarani/Conduit) | Swift model abstraction and provider interoperability | Compare provider boundaries without making cloud paths local core |
| [SwiftAgent](https://github.com/mi12n/SwiftAgent) | Native Swift agent-building primitives | Extract Swift concurrency/tool patterns only after evidence |
| [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit) | Swift-native agent runtime patterns | Compare checkpoints, approvals, and local providers |
| [Swarm](https://github.com/openai/swarm) | Lightweight handoff and multi-agent coordination | Extract handoff semantics; require durable state |

### Capability scores — models and runtime aspects

| Reference | On-device | Swift-native | Artifact / lifecycle | Tools / structured output | Streaming / cancel | Ecosystem | Evidence | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Foundation Models | 5 | 5 | 3 | 5 | 4 | 3 | 4 | **4.1** | ✅ |
| Core ML | 5 | 5 | 5 | 4 | 4 | 4 | 5 | **4.6** | ✅ |
| MLX Swift | 5 | 5 | 3 | 3 | 4 | 4 | 4 | **4.0** | ✅ |
| Hugging Face Swift | 3 | 5 | 4 | 3 | 4 | 5 | 3 | **3.9** | ⚠️ |
| AnyLanguageModel | 2 | 5 | 2 | 4 | 3 | 4 | 2 | **3.1** | ⚠️ |
| Conduit | 3 | 5 | 3 | 4 | 4 | 4 | 3 | **3.7** | ⚠️ |
| SwiftAgent | 3 | 5 | 2 | 4 | 3 | 3 | 2 | **3.1** | ⚠️ |
| AgentRunKit | 4 | 5 | 3 | 4 | 4 | 3 | 3 | **3.7** | ⚠️ |
| Swarm | 3 | 5 | 2 | 3 | 3 | 3 | 2 | **3.0** | ⚠️ |
| ArchonModels / Agent contract | 5 | 5 | 5 | 5 | 5 | 5 | 4 | **4.9** | ✅ |

### Market-aware comparator scores — models and runtimes

| Reference | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| Foundation Models | 3 | 5 | 5 | 5 | 5 | 5 | **90** | REUSE Apple foundation |
| Core ML | 3 | 4 | 5 | 5 | 5 | 5 | **86** | REUSE runtime; BUILD lifecycle |
| MLX Swift | 2 | 4 | 5 | 4 | 3 | 4 | **72** | ADAPT local provider |
| Hugging Face Swift | 2 | 4 | 3 | 4 | 4 | 4 | **66** | ADAPT catalog/artifact tooling |
| AnyLanguageModel | 2 | 3 | 2 | 3 | 3 | 3 | **51** | PENDING narrow provider probe |
| Conduit | 2 | 3 | 2 | 3 | 3 | 3 | **51** | PENDING/ADAPT reference |
| SwiftAgent | 2 | 3 | 3 | 2 | 2 | 3 | **50** | INSPIRATION |
| AgentRunKit | 2 | 3 | 3 | 3 | 3 | 3 | **55** | PENDING/ADAPT reference |
| Swarm | 2 | 3 | 2 | 2 | 2 | 2 | **44** | PENDING upstream evidence |
| ArchonModels / Agent contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | ADAPT; device/runtime gates open |

## 6. Protocols and interoperability

Source records: the protocols comparison in this document.

### Capability scores — protocol aspects

| Reference | Tools / resources / prompts | Progress / cancellation | Swift / local | Auth / consent | Lifecycle / recovery | Interoperability evidence | Average / 5 | Local gate |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 5 | 5 | 5 | 4 | 3 | 4 | **4.3** | ✅ |
| [A2A](https://a2a-protocol.org/latest/specification/) | 4 | 4 | 2 | 3 | 3 | 3 | **3.2** | ⚠️ |
| [AG-UI](https://docs.ag-ui.com/) | 3 | 4 | 2 | 3 | 2 | 3 | **2.8** | ⚠️ |
| ArchonConnect contract | 5 | 5 | 5 | 5 | 4 | 4 | **4.7** | ✅ |

### Market-aware comparator scores — protocols

| Reference | Pull | Diff. | Local | Quality | Maintain. | Fit | Overall / 100 | Decision |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| MCP Swift SDK | 2 | 5 | 5 | 4 | 4 | 5 | **80** | ADAPT official SDK; policy remains Archon-owned |
| A2A | 2 | 4 | 1 | 3 | 3 | 3 | **51** | PENDING identity/auth/device evidence |
| AG-UI | 2 | 4 | 1 | 3 | 3 | 3 | **51** | PENDING lifecycle/device evidence |
| ArchonConnect contract | 2 | 5 | 5 | 4 | 4 | 5 | **80** | ADAPT; production conformance open |

### Protocol implementation decision

| Keep from the market | Archon implementation boundary | Required proof |
| --- | --- | --- |
| MCP tools, resources, prompts, schemas | Official MCP Swift SDK behind Archon-owned values | Pagination, invalid schema, structured output, and content tests |
| Progress and cancellation | Archon transport events and request context | Loopback and production-server lifecycle tests |
| Consent and authorization | Host-owned credentials, permissions, risk policy, and redaction | Auth, disconnect, arbitrary notification, and consent tests |
| A2A/AG-UI concepts | Keep as pending interoperability references | Identity, replay, cancellation, privacy, and device boundary proof |

## 7. Archon product readiness

This is the full product scorecard for every package product in
`swift package dump-package`, including the developer CLI and reference app.
`ArchonAgentMacros` is an internal target rather than a separately published
product, so it is not scored here.

The user-pull score is `0` when this repository has no independent adoption,
retention, or repeated-request evidence. That is an evidence score, not a claim
that users do not value the product. The package is not a market product with
measured retention data yet, so the scores below are engineering-readiness
scores and remain provisional until consuming-app and device evidence exists.

| Product | Surface | Differentiation / 5 | Local feasibility / 5 | Quality / safety / 5 | Maintainability / 5 | Strategic fit / 5 | Engineering / 100 | User-pull evidence | Confidence | Current posture |
| --- | --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- | --- |
| `ArchonCore` | SDK | 4 | 5 | 4 | 5 | 5 | **91** | None recorded | Medium | REUSE Apple primitives; build policy |
| `ArchonModels` | SDK | 5 | 5 | 4 | 4 | 5 | **93** | None recorded | Medium | ADAPT runtimes; build lifecycle |
| `ArchonAgent` | SDK | 5 | 5 | 4 | 4 | 5 | **93** | None recorded | Medium | ADAPT patterns; recovery gates open |
| `ArchonContext` | SDK | 4 | 5 | 4 | 5 | 5 | **91** | None recorded | Medium | BUILD focused boundary |
| `ArchonMemory` | SDK | 5 | 5 | 4 | 4 | 5 | **93** | None recorded | Medium | BUILD semantics; index adoption pending |
| `ArchonMemoryProxima` | Optional adapter | 3 | 5 | 3 | 3 | 4 | **73** | None recorded | Medium | ADAPT; persistence/device gates open |
| `ArchonSearch` | SDK | 5 | 5 | 4 | 4 | 5 | **93** | None recorded | Medium | BUILD local orchestrator |
| `ArchonSandbox` | SDK | 5 | 5 | 4 | 4 | 5 | **93** | None recorded | Medium | BUILD safety boundary |
| `ArchonConnect` | SDK | 4 | 5 | 4 | 4 | 5 | **88** | None recorded | Medium | ADAPT official SDK; conformance open |
| `ArchonComputerUse` | SDK | 5 | 5 | 3 | 4 | 5 | **89** | None recorded | Low | BUILD semantic controller; app validation open |
| `ArchonModelsUI` | SDK | 4 | 5 | 3 | 4 | 4 | **81** | None recorded | Low | BUILD SwiftUI surface; app validation open |
| `ArchonFull` | SDK facade | 5 | 5 | 4 | 5 | 5 | **96** | None recorded | Medium | REUSE facade; no duplicated logic |
| `archon-model` | Developer CLI | 3 | 3 | 4 | 4 | 3 | **67** | None recorded | Medium | BUILD validation/tooling surface |
| `archon-example-app` | Reference host | 3 | 3 | 3 | 3 | 3 | **60** | None recorded | Low | Reference only; not production acceptance |

### Product score calculation examples

| Product | Calculation | Result |
| --- | --- | :---: |
| `ArchonModels` | `(5 × 26.67%) + (5 × 26.67%) + (4 × 20%) + (4 × 13.33%) + (5 × 13.33%)` | **93 / 100** |
| `ArchonMemoryProxima` | `(3 × 26.67%) + (5 × 26.67%) + (3 × 20%) + (3 × 13.33%) + (4 × 13.33%)` | **73 / 100** |
| `ArchonComputerUse` | `(5 × 26.67%) + (5 × 26.67%) + (3 × 20%) + (4 × 13.33%) + (5 × 13.33%)` | **89 / 100** |

## 8. Cross-category feature extraction map

| User outcome worth keeping | Primary references | Archon owner | Decision | Acceptance gate |
| --- | --- | --- | --- | --- |
| Memory appears without manual curation | Mem0, Supermemory | `ArchonMemory` | ADAPT + BUILD | Extraction, dedupe, contradiction, delete, audit |
| Facts change over time without losing history | Zep | `ArchonMemory` | BUILD semantics | Temporal validity, supersession, migration |
| Agent controls immediate working context | Letta | `ArchonMemory` + `ArchonContext` | ADAPT | Scope, limit, consent, replay |
| Long-running graph can pause and recover | LangGraph | `ArchonAgent` | ADAPT | Checkpoint, fork, replay, idempotence |
| Delegation stays typed and observable | OpenAI Agents SDK, CrewAI | `ArchonAgent` | ADAPT | Handoffs, guardrails, traces, cancellation |
| Web content becomes structured evidence | Tavily, Exa, Firecrawl | `ArchonSearch` | BUILD + ADAPT | Crawl bounds, provenance, citations, prompt injection |
| Search sources remain controllable | Brave, SearXNG, SerpAPI | `ArchonSearch` | ADAPT | Provider policy, source metadata, network disclosure |
| Untrusted execution is isolated and auditable | E2B, Modal, Deno Sandbox | `ArchonSandbox` | BUILD local; ADAPT remote | Isolation label, secrets, quotas, cleanup |
| Browser work uses semantic actions | Stagehand, TinyFish | `ArchonComputerUse` | BUILD semantic controller | Stale state, approvals, postconditions |
| Local inference uses supported Apple runtimes | Foundation Models, Core ML | `ArchonModels` | REUSE + ADAPT | Artifact/runtime match, device, memory, offline inference |
| Tools and resources interoperate | MCP Swift SDK | `ArchonConnect` | ADAPT | Conformance, auth, cancellation, lifecycle |

## 9. Decision rules and next actions

### Reuse

Reuse public Apple frameworks when the capability is current, supported, and
complete for the requirement. Archon adds policy, lifecycle, artifact, or host
boundaries around the framework; it does not recreate the framework.

### Adapt

Adapt a candidate when it provides a qualifying local Swift capability but
Archon still needs vendor-neutral types, stricter safety, lifecycle control,
compatibility, or a missing contract. The dependency remains product-scoped and
must not leak vendor types into default APIs.

### Build

Build when no complete qualifying local Swift implementation exists, or when
the existing implementation is unmaintained, unsafe, materially incomplete,
or incompatible with Archon's recovery/privacy requirements.

### Pending

Keep a capability pending when package, license, user-pull, device, production
server, or security evidence is incomplete. Never turn a successful README
inspection, cloud demo, or package build into a replacement claim.

### Next evidence sequence

| Priority | Work | Products | Exit evidence |
| :---: | --- | --- | --- |
| 1 | Complete memory adapter comparison | `ArchonMemory`, `ArchonMemoryProxima` | Recall, p95, memory ceiling, update/delete, recovery, migration, iOS device |
| 2 | Complete graph recovery and side-effect tests | `ArchonAgent` | Crash/reopen, fork/replay, handoff, cancellation, idempotence |
| 3 | Complete offline and citation workloads | `ArchonSearch` | Network denied local results, bounded crawl, dedupe, verifiable citations |
| 4 | Threat-model local action boundaries | `ArchonSandbox`, `ArchonComputerUse` | CSP/path/quota/audit tests, stale-state and approval evidence |
| 5 | Complete official MCP lifecycle decision | `ArchonConnect` | Production-server conformance, authorizer, notification, teardown |
| 6 | Validate model/UI paths in an app | `ArchonModels`, `ArchonModelsUI`, `ArchonFull` | Signed app, real artifact, accessibility, physical-device evidence |

## Evidence and maintenance policy

- Re-score when a competitor changes a primary capability, when independent
  user-pull evidence arrives, or when Archon closes a quality gate.
- Keep capability evidence separate from user-pull evidence. Official docs show
  that a feature exists; they do not prove that users love it.
- Keep cloud, hosted browser, localhost-server, and non-Swift references visible
  but label them as adapters or inspiration rather than local replacements.
- Preserve the exact source links, revisions, licenses, limitations, and open
  gates in this comparison and its linked official sources.
- Do not change a default dependency or public API from this document alone.
  Adoption requires the [release validation guide](../how-to/validate-a-release.md),
  migration/recovery evidence, and the consuming-app/device gates.
