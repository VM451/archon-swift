# Product reference

Archon products are independent SwiftPM imports. Prefer the smallest product
set that satisfies the application so optional runtimes and UI do not become
unnecessary dependencies.

| Product | Use it for | Key boundary |
| --- | --- | --- |
| [`ArchonCore`](products/core.md) | Capabilities, device facts, permissions, logging, identifiers, errors | Shared foundation only |
| [`ArchonModels`](products/models.md) | Catalogs, model formats, licensing, compatibility, downloads, installation, loading hooks | Host supplies model-family adapters and credentials |
| [`ArchonAgent`](products/agent.md) | Graph execution, routing, tools, interrupts, checkpoints, tracing, evaluation, provider adapters | Does not own model downloads |
| [`ArchonContext`](products/context.md) | Deterministic request-scoped context assembly | Does not persist or execute |
| [`ArchonMemory`](products/memory.md) | Durable facts, graph/vector retrieval, RAG, profile/context synthesis, optional CloudKit sync | Local store is authoritative |
| [`ArchonMemoryProxima`](products/memory-proxima.md) | Optional ProximaKit dense-index adapter | Not included in `ArchonFull` |
| [`ArchonSearch`](products/search.md) | Discovery, crawl, extraction, research, citations, monitoring | Network sources require explicit policy |
| [`ArchonSandbox`](products/sandbox.md) | Capability-restricted WebKit workspaces, DOM/JS bridge, workspace sync | In-process WebKit is not VM isolation |
| [`ArchonConnect`](products/connect.md) | MCP tools, resources, prompts, JSON-RPC/streamable HTTP, permissions | Host resolves credentials and server lifecycle |
| [`ArchonComputerUse`](products/computer-use.md) | Semantic snapshots, risk checks, host actions, postconditions | Host supplies observations and side effects |
| [`ArchonModelsUI`](products/models-ui.md) | SwiftUI model library, discovery, detail, storage, and download surfaces | Uses the host-registered `ModelLibrary` |
| [`ArchonFull`](products/full.md) | Convenient import of the base SDK family | Facade only; excludes optional adapters |

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
