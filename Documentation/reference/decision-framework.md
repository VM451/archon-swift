# Reuse, adapt, build, and pending decisions

`PARTIAL / ADAPT` is the reader-friendly label for the canonical `ADAPT`
decision. The decision describes what Archon should do with a capability; it
does not describe how popular or feature-rich the reference product is.

| Decision | Use when | Archon action | Current examples |
| --- | --- | --- | --- |
| **REUSE** | A public Apple or Swift package already provides the needed local, in-process capability | Use it directly; keep Archon policy around it | Foundation Models, Core ML, WebKit, SwiftUI, CloudKit, App Intents |
| **PARTIAL / ADAPT** | An existing component solves part of the problem but misses Archon policy, lifecycle, or native boundary requirements | Wrap it behind vendor-neutral Archon APIs and add the missing contract | MLX Swift, Hugging Face Swift, ProximaKit, official MCP Swift SDK |
| **BUILD** | No qualifying local-native capability exists, or the existing one is materially incomplete | Own the implementation using public Apple APIs and tested Swift infrastructure | Agent graphs, memory semantics, local search index, sandbox policy, Computer Use safety |
| **INSPIRATION** | The reference is cloud-hosted, server-dependent, or not native Swift | Extract the user outcome and design pattern; do not make it an Archon core dependency | Mem0, Zep, LangGraph, Tavily, Firecrawl, E2B, Stagehand |
| **PENDING** | Platform, license, security, maintenance, or user-value evidence is incomplete | Do not adopt or claim parity until the evidence gate closes | Unverified native candidates and unmeasured replacement paths |

The detailed feature-by-feature comparison, scores, evidence, and open gates
are in [competitor-comparison.md](competitor-comparison.md).

## Dependency and product policy

The package is layered so an app can adopt only what it needs. `ArchonFull`
re-exports the base SDK products, but it does not pull in the optional Proxima
index adapter. Cloud models, search services, remote MCP servers, and remote
sandboxes belong behind the consuming app's explicit adapter and permission
boundary.

| If you need… | Import | Additional dependency scope |
| --- | --- | --- |
| Shared policies, device facts, errors | `ArchonCore` | None |
| Catalogs, artifacts, downloads, model UI | `ArchonModels`, `ArchonModelsUI` | Runtime integrations are opt-in at the API boundary |
| Graph agents and local model adapters | `ArchonAgent` | MLX, MLX LM, Hugging Face, Transformers, and Swift macros |
| Durable memory and RAG | `ArchonMemory` | GRDB/SQLite |
| Alternative dense indexing | `ArchonMemoryProxima` | ProximaKit; optional and not included in `ArchonFull` |
| MCP connectivity | `ArchonConnect` | Official MCP Swift SDK |
| Search, sandbox, semantic actions | `ArchonSearch`, `ArchonSandbox`, `ArchonComputerUse` | Archon-owned contracts; integrations remain explicit |

No cloud-vendor SDK is required by the base local policies. Cloud models,
search services, remote MCP servers, and remote sandboxes belong behind the
consuming app's explicit adapter and permission boundary.
