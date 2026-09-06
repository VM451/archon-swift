# ArchonAgent

`ArchonAgent` executes typed, stateful graphs and coordinates model providers,
tools, memory, context, search, sandbox, and host actions through explicit
boundaries.

## Core pieces

- `AgentState` is the Codable/Sendable state carried through a graph.
- `GraphBuilder` validates and compiles nodes and static, conditional, or branch
  edges; invalid graphs fail at compile time with `GraphError.invalidGraph`.
- `Graph` streams lifecycle events or returns a final state. Nodes can call
  `context.emit(ModelResponseChunk(...))` to forward incremental model output
  as `GraphEvent.modelResponseChunk`; `resumeStream` preserves the same event
  contract after an approval or recovery boundary.
- `StateCheckpointer` persists thread history, supports latest-state recovery,
  deletion, and forks.
- `GraphInterrupt` supports approval or pause points.
- Tool registries, model policies, tracing, token accounting, and evaluation
  harnesses remain independently configurable.
- `ToolEffectLedger` atomically reserves call IDs, records successful
  idempotent tool receipts, and replays completed effects instead of executing
  them twice.

`AgentViewModel` is `@MainActor`-isolated for SwiftUI safety. Its `start` and
`resume` methods return awaitable `Task<Void, Never>` handles, so a host can
bind deterministic lifecycle tests or cancellation to actual execution rather
than timing sleeps. Completed streamed text is committed as an assistant
`ChatMessage`.

The graph does not download models. `ModelPolicy` and the routing layer select
an explicitly permitted provider; `localOnly` never silently chooses a cloud
provider and can explicitly prefer Apple's Foundation Models runtime when the
device reports it available. `ArchonAgent` includes the MLX/Hugging Face
dependencies needed by `MLXLocalProvider` so the bundled local path is ready
without another provider package. Use the consuming app for credentials,
side-effect approval, and host-specific non-MLX model adapters.

Custom `ToolEffectLedger` conformances must implement the reserve/record/release
protocol. `record` is valid only after a successful reservation; release a
reservation when execution is skipped or fails before producing a receipt.

## Adaptive local model selection

`AdaptiveModelCatalog` is the family-neutral input to
`OnDeviceProvider.adaptive(...)`. For user-facing model selection, populate it
from the MLX-only catalog boundary. It accepts validated MLX Hugging Face
sources and imported MLX directories; lower-level Core AI candidates remain
explicit host integrations. A candidate carries its runtime contract,
peak-memory estimate, context, device/platform constraints, optional measured
quality/speed/prompt-speed/energy/thermal metadata, download size, and license.

The selector applies hard platform, runtime, context, minimum-RAM, Core AI,
and generic peak-memory gates before ranking eligible candidates. Missing
benchmark metadata is not invented. Automatic runtime selection keeps MLX
dynamic weights separate from Core AI exports; Core AI requires an explicit
preference or a compatible Core AI-only catalog.

The bundled catalog is a small Gemma compatibility seed and retains the
existing Gemma convenience API; it is not a complete model-family allow-list.
Applications should refresh descriptors from
`ArchonModels` catalog providers (or use `AdaptiveModelCatalog.load(from:)`)
and pass a new `AdaptiveModelCatalog` to `OnDeviceProvider` or
`ArchonAI.adaptive(...)` when new model releases are approved. Raw GGUF,
SafeTensors, and Transformers weights remain
conversion-required and are not made runnable by catalog metadata alone.

For a dynamic Hugging Face catalog used for user-facing browsing, wrap it in
`OfficialModelCatalog` and request `runtime: .mlx`, `format: .mlx`, and a task
such as `textGeneration` before constructing the adaptive catalog. This asks
the Hub for MLX-tagged first-party packages instead of relying on its popular
raw checkpoint list.
`AdaptiveModelCatalog.load(from:)` applies this MLX boundary automatically for
AI-agent catalog loading, but explicit `OfficialModelCatalog` wrapping remains
the required choice when sharing the catalog with a user-facing UI.

See [Supported models and model-family policy](../supported-models.md) for
catalog wiring, runtime/artifact support, and the AI-agent guidance.
