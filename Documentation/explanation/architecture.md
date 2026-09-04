# System architecture

Archon is a layered SwiftPM family. Each product owns one capability boundary,
and composition happens through protocols, actors, and host injection rather
than through a central service process.

## Product graph

```text
ArchonCore
  ├── ArchonModels
  ├── ArchonContext
  ├── ArchonMemory
  ├── ArchonSearch
  ├── ArchonSandbox
  ├── ArchonConnect
  └── ArchonComputerUse

ArchonAgent ──> ArchonCore + ArchonModels
ArchonModelsUI ──> ArchonCore + ArchonModels
ArchonFull ──> base public products
ArchonMemoryProxima ──> ArchonMemory + ProximaKit (optional)
```

`ArchonFull` is a facade, not a second implementation. It re-exports the base
products and intentionally excludes `ArchonMemoryProxima`, so importing the
facade does not force an optional dense-index dependency.

## Ownership boundaries

| Concern | Owner | Non-owner responsibilities |
| --- | --- | --- |
| Capabilities, device facts, permissions, logging, errors | `ArchonCore` | Does not implement memory, search, inference, MCP, or sandboxing |
| Catalog metadata, compatibility, downloads, installation | `ArchonModels` | Does not own model-family tokenizers or app credentials |
| Runtime execution | `ModelRuntimeAdapter` implementations | Does not own catalog or installation state |
| Agent graph state and routing | `ArchonAgent` | Does not download models or silently choose cloud providers |
| Request context | `ArchonContext` | Does not persist memory or execute actions |
| Durable memory and retrieval | `ArchonMemory` | Does not make request context or model inference authoritative |
| Current-information research | `ArchonSearch` | Does not make network access implicit under `localOnly` |
| Restricted mini-app execution | `ArchonSandbox` | Does not claim WebKit is a process, container, or microVM |
| Protocol connectivity | `ArchonConnect` | Does not discover or persist credentials |
| Host application actions | `ArchonComputerUse` | Does not emit device-wide coordinate events |
| SwiftUI model surfaces | `ArchonModelsUI` | Does not create a second model store |

## Request flow

1. The host app selects a model, memory, search, tool, and permission policy.
2. `ArchonAgent` runs a typed graph and asks contributors for current context.
3. `ArchonContext` orders and bounds fragments for the current request.
4. Tools call explicitly authorized memory, search, MCP, sandbox, or host-action
   boundaries.
5. Checkpoints, traces, and results are persisted only by their configured
   owners.

Every step is cancellable. Missing host services produce typed failures or
unavailable results; Archon does not fabricate inference, search, writes, or
platform records.

## Package-only evidence

The repository can prove SwiftPM compilation, package tests, CLI behavior, and
simulator compilation. A signed app is required to prove entitlements,
privacy-usage descriptions, live SwiftUI behavior, App Intents registration,
physical-device performance, and model-specific tokenizer/runtime behavior.

See [dependency ownership](dependency-ownership.md), [local-first boundaries](local-first-boundaries.md), and the [product reference](../reference/products.md).
