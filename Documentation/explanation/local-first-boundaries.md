# Local-first boundaries

“Local” has a precise meaning in Archon: the capability runs in-process on the
user's Apple device through native Swift/SwiftPM APIs and does not require a
cloud service or a separate local server. A product can be useful and still be
an adapter rather than a local-core replacement.

## Boundary matrix

| Capability | Default local path | Explicit remote path | Required disclosure |
| --- | --- | --- | --- |
| Model inference | Apple Foundation Models, Core AI, or MLX when available | Cloud or private-cloud provider | Runtime, capability, and network policy |
| Model discovery | `StaticModelCatalog` or `LocalModelCatalog` | Hugging Face or HTTP catalog | Catalog network dependence |
| Search | `DiscoverySource.localWorkspace` with `localOnly` | Web/cloud provider with `networkAllowed` | `SearchResponse.usedNetwork` |
| Memory | Local GRDB/SQLite and local indexes | Optional CloudKit sync or host adapter | Durable local source of truth |
| Sandbox execution | `InProcessWebKitExecutionProvider` | Remote container or microVM | `IsolationLevel` and network dependence |
| MCP | Host-local transport if supplied | HTTP/streamable-HTTP server | Endpoint and credentials belong to host |
| Computer Use | Host-provided semantic observations/actions | Remote browser or screenshot adapter | Risk, approval, and postcondition behavior |

## Policy invariants

- `localOnly` never silently calls the network.
- `preferLocal` may fall back only when the host explicitly permits the
  fallback through its selected provider policy.
- Cloud credentials belong to the consuming app's secure boundary.
- A hosted browser or microVM is not described as local execution.
- Unavailable capability is an explicit result, not fabricated output.

## Why this matters

This boundary lets an application make a meaningful privacy and reliability
choice. It also makes competitor comparison honest: a cloud product may have a
stronger feature, but it has not replaced the local Swift implementation unless
it passes the local qualification gate.

Evidence and adoption decisions are maintained in the
[competitor signature registry](../../context/competitor-signature-features.md),
[adoption backlog](../../context/feature-adoption-backlog.md), and
[quality scorecard](../../context/quality-scorecard.md).
