# Dependency ownership

Archon keeps dependencies at the narrowest product boundary that can own them.
This reduces binary cost, keeps products independently adoptable, and prevents
vendor APIs from leaking through default Archon contracts.

## Direct dependency map

| Product | Direct dependencies | Why they live here |
| --- | --- | --- |
| `ArchonCore` | None | Stable shared primitives stay lightweight |
| `ArchonModels` | `ArchonCore` | Catalog and lifecycle contracts do not require a model runtime |
| `ArchonAgent` | `ArchonCore`, `ArchonModels`, Swift Syntax macros, MLX Swift/LM, Hugging Face, Transformers | Agent execution owns provider and local-runtime adapters |
| `ArchonContext` | `ArchonCore` | Request assembly is intentionally independent of durable storage |
| `ArchonMemory` | `ArchonCore`, GRDB | SQLite-backed durable memory owns its persistence engine |
| `ArchonMemoryProxima` | `ArchonMemory`, ProximaKit | Optional dense indexing stays replaceable and out of `ArchonFull` |
| `ArchonSearch` | `ArchonCore` | Search uses Archon-owned contracts and host transports |
| `ArchonSandbox` | `ArchonCore` | WebKit is an Apple platform boundary, not a remote runtime dependency |
| `ArchonConnect` | `ArchonCore`, official MCP Swift SDK | MCP wire behavior is reused; Archon owns policy and error boundaries |
| `ArchonComputerUse` | `ArchonCore` | Host observation and action closures remain app-owned |
| `ArchonModelsUI` | `ArchonCore`, `ArchonModels` | UI reads the same model actors used by the library |
| `ArchonFull` | Base Archon products | Re-export facade only |

## Reuse rule

A package is eligible for the local core only when its capability is:

- available on Apple platforms;
- callable through an in-process Swift/SwiftPM API;
- usable without a required cloud service or local server; and
- maintainable under Archon's Swift 6 strict-concurrency and safety contracts.

Apple frameworks are preferred when they already provide the capability. The
official MCP Swift SDK is reused for protocol behavior. MLX, Hugging Face, GRDB,
and ProximaKit are kept behind the products that need them. Cloud providers and
hosted services are adapters, not hidden base dependencies.

## API hygiene

- Public Archon protocols use vendor-neutral types.
- Credentials are supplied by the host and never embedded in defaults.
- Optional products are explicit imports.
- Runtime, network, isolation, and availability are represented in metadata.
- A missing optional dependency fails closed rather than being represented as a
  successful no-op.

The current dependency decision and evidence records live in
[`context/dependency-decision-log.md`](../../context/dependency-decision-log.md),
[`context/capability-ownership-matrix.md`](../../context/capability-ownership-matrix.md),
and the [competitor registry](../../context/competitor-signature-features.md).
