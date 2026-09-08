# ArchonCore — how it works

`ArchonCore` supplies shared primitives only: capabilities, policy, typed
errors, device facts, identifiers, network guards, and the vendor-neutral
structured-output contract. It contains no memory, search, inference, MCP,
sandbox, or Computer Use implementation.

```mermaid
flowchart TD
    App[Consuming app] --> Registry[ArchonCapabilityRegistry]
    App --> Policy[ArchonNetworkPolicy / ArchonNetworkSecurity]
    App --> SOP[ArchonStructuredOutputProvider]
    Registry --> Facts[Device facts + availability checks]
    Policy --> Gate{Local-only or public-HTTPS?}
    Gate -->|Pass| Feature[Product feature proceeds]
    Gate -->|Fail| Err[Typed fail-closed error]
    SOP --> Agent[ArchonAgent.LLMProvider conformance]
    SOP --> Mem[ArchonMemory explicit adapter]
```

Cross-module composition uses protocols and host injection; products depend
on `ArchonCore`, never the reverse.
