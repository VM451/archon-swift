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

The graph does not download models. `ModelPolicy` and the routing layer select
an explicitly permitted provider; `localOnly` never silently chooses a cloud
provider. Use the consuming app for credentials, side-effect approval, and
host-specific model adapters.
