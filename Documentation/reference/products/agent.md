# ArchonAgent

`ArchonAgent` executes typed, stateful graphs and coordinates model providers,
tools, memory, context, search, sandbox, and host actions through explicit
boundaries.

## Core pieces

- `AgentState` is the Codable/Sendable state carried through a graph.
- `GraphBuilder` compiles nodes and static, conditional, or branch edges.
- `Graph` streams lifecycle events or returns a final state.
- `StateCheckpointer` persists thread history, supports latest-state recovery,
  deletion, and forks.
- `GraphInterrupt` supports approval or pause points.
- Tool registries, model policies, tracing, token accounting, and evaluation
  harnesses remain independently configurable.
- `ToolEffectLedger` records successful idempotent tool receipts so recovery
  can replay a completed side effect instead of executing it twice.

The graph does not download models. `ModelPolicy` and the routing layer select
an explicitly permitted provider; `localOnly` never silently chooses a cloud
provider and can explicitly prefer Apple's Foundation Models runtime when the
device reports it available. Use the consuming app for credentials,
side-effect approval, and host-specific model adapters.

## Adaptive local model selection

`AdaptiveModelCatalog` is the family-neutral input to
`OnDeviceProvider.adaptive(...)`. It accepts candidates from any validated
local family, including MLX Hugging Face sources, imported MLX directories,
and declared Core AI exports. A candidate carries its runtime contract,
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

For a dynamic Hugging Face local catalog, request `runtime: .mlx` and a task
such as `textGeneration` before constructing the adaptive catalog. This asks
the Hub for MLX-tagged runnable packages instead of relying on its popular raw
checkpoint list.

See [Supported models and model-family policy](../supported-models.md) for
catalog wiring, runtime/artifact support, and the AI-agent guidance.
