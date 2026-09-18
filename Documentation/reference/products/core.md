# ArchonCore

`ArchonCore` is the lightweight shared foundation. It defines values and
policies used by other products without owning their storage, inference,
transport, or UI implementation.

## Main contracts

- `ArchonPermission` describes capabilities such as network, storage,
  clipboard, camera, microphone, location, and external URLs.
- `ArchonCapability` and platform/version values describe availability without
  inventing support.
- `ArchonCapabilityRegistry` provides an actor-isolated local registry for
  host-observed capability status and required permissions. `require` fails
  closed unless the capability is available and the host supplies every
  required permission.
- Capability observations include explicit `unsupported` and `degraded`
  states plus timestamps, so a stale or partial host report is not treated as
  ready.
- `ArchonDeviceCapabilities.current` reports device, OS, memory, architecture,
  thermal, and Apple runtime availability facts.
- `ArchonLogger` provides an injectable logging boundary; the default logger is
  a no-op.
- `ArchonAuditEvent` and `ArchonAuditSink` provide structured, redacted audit
  events for policy decisions and network boundaries. The package does not
  persist credentials or grant host permissions.
- Shared model runtime/task/capability values are used by model and agent
  routing.

Keep host authorization and user-facing permission prompts in the consuming
application. `ArchonCore` describes policy and observes host facts; it does not
grant Apple's system permissions.

## Agent-stack probe IDs

`ArchonCapabilityProbeID` provides well-known capability identifiers for
agent-stack availability probes (`archon.agent.handoff`,
`archon.agent.guardrails`, `archon.agent.eval`,
`archon.context.token-profiles`, `archon.context.summarization`,
`archon.context.contributor-latency`). `ArchonCapabilityRegistry`
gains a `registerAvailable` convenience for recording an available status.
These are constants only; capability state remains host-observed.
