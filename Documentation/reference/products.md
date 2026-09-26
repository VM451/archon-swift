# Product reference

Archon products are independent SwiftPM imports. Prefer the smallest product
set that satisfies the application so optional runtimes and UI do not become
unnecessary dependencies.

The `Honest winner` column states who wins each row — Archon or its
competitors — because every product runs locally on the user's device with no
required hosting, so some rows are wins and some are honest losses. Scores and
evidence live in the [competitor comparison](competitor-comparison.md);
latency/recall device proof lives in
[Benchmarks](../../Benchmarks/README.md).

| Product | Use it for | Honest winner | Key boundary |
| --- | --- | --- | --- |
| [`ArchonCore`](products/core.md) | Capabilities, device facts, permissions, logging, identifiers, errors | 🤝 Split — Apple/upstream wins primitives (reused by design); Archon wins the unified policy/error layer | Shared foundation only |
| [`ArchonModels`](products/models.md) | Catalogs, model formats, licensing, compatibility, downloads, installation, loading hooks | 🤝 Split — Hugging Face wins catalog breadth; Archon wins native lifecycle + official-publisher MLX browsing, now with prep recipes and measured benchmarks | Host supplies model-family adapters and credentials |
| [`ArchonAgent`](products/agent.md) | Graph execution, routing, tools, handoffs, guardrails, interrupts, checkpoints, tracing, evaluation, provider adapters, realtime voice + vision sessions | 🏆 Archon on-device — durability, handoffs, guardrails, eval, full-duplex realtime sessions proven; LangGraph still leads hosted/Python ecosystem maturity | Does not own model downloads |
| [`ArchonContext`](products/context.md) | Deterministic request-scoped context assembly | 🏆 Archon — no local rival; token profiles, summarization seam, latency budgets extend the lead | Does not persist or execute |
| [`ArchonMemory`](products/memory.md) | Durable facts, graph/vector retrieval, RAG, profile/context synthesis, source-linked competitive research, local feedback, optional CloudKit sync | 🏆 Archon on-device — beats Wax (6.4x ingest, 1.4x p95, equal recall); hybrid ranking + temporal supersession extend the lead; hosted rivals win zero-ops convenience | Local store is authoritative |
| [`ArchonMemoryProxima`](products/memory-proxima.md) | Optional ProximaKit dense-index adapter | 🏆 Archon leads — beats USearch 2.8x on iPhone 16 at equal recall; stays optional until ceiling/device gates close | Not included in `ArchonFull` |
| [`ArchonSearch`](products/search.md) | Discovery, registry fan-out, keyword + neural rerank, freshness, crawl, extraction, research, citations, monitoring | 🤝 Split — rivals win whole-web scale (structural); Archon wins offline corpus, privacy, explicit policy; local rerank + answer evals narrow the quality gap | Network sources require explicit policy |
| [`ArchonSandbox`](products/sandbox.md) | Capability-restricted WebKit workspaces, DOM/JS bridge, workspace sync | 🤝 Split — rivals win isolation strength (microVM, structural); Archon wins native in-process embedding + policy; capability grants, audit stream, WASM path extend it | In-process WebKit is not VM isolation |
| [`ArchonConnect`](products/connect.md) | MCP tools, resources, prompts, JSON-RPC/streamable HTTP, permissions | 🤝 Split — official SDK wins wire protocol (adapted); Archon wins permission/policy + hosted capabilities; teardown + conformance probes harden the adapter | Host resolves credentials and server lifecycle |
| [`ArchonComputerUse`](products/computer-use.md) | Semantic snapshots, risk checks, host actions, postconditions | 🤝 Split — rivals win automation breadth; Archon wins semantic-first safety (approvals, postconditions, catalogued actions, no coordinate taps) | Host supplies observations and side effects |
| [`ArchonModelsUI`](products/models-ui.md) | SwiftUI model library, discovery, detail, storage, and download surfaces | 🤝 Split — LM Studio/Jan win full-app UX maturity; Archon wins embeddable native SwiftUI, now with benchmark badges + storage analytics | Uses the host-registered `ModelLibrary` |
| [`ArchonFull`](products/full.md) | Convenient import of the base SDK family | — (facade; no matchup) | Facade only; excludes optional adapters |

## Executable products

| Executable | Intended use | Runtime boundary |
| --- | --- | --- |
| `archon-model` | Developer-side model inspection, validation, packaging, conversion, and preparation benchmarks | macOS tool; never an iOS runtime dependency |
| `archon-example-app` | Buildable SwiftUI model-library example | Directly runnable with `swift run` on macOS; iOS/visionOS need an Xcode host |

## Selection examples

```swift
// Lightweight local model metadata and lifecycle.
import ArchonModels

// Durable local memory without the optional dense-index adapter.
import ArchonMemory

// Add this only when the ProximaKit index has passed your device gates.
import ArchonMemoryProxima
```

`ArchonFull` is useful for application composition and examples, but a library
or feature module should normally import its direct product to keep the
dependency graph obvious.
