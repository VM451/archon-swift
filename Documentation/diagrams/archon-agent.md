# ArchonAgent — how it works

`ArchonAgent` executes provider-routed agent graphs with typed tools,
interrupts, checkpointing, evaluation, and observability. It requests model
selection from `ArchonModels` descriptors but never downloads models itself.

```mermaid
flowchart TD
    Graph[GraphBuilder: nodes + edges + entry points] --> Valid{Structure validation}
    Valid -->|Valid| Exec[Graph execution]
    Valid -->|Invalid| TErr[Typed build error]
    Exec --> Route[AdaptiveModelCatalog: rank runnable candidates]
    Route --> Prov{Provider selection}
    Prov --> MLX[MLXLocalProvider — on-device]
    Prov --> FM[Foundation Models — when available]
    Prov --> Cloud[Cloud provider — explicit fallback only]
    Exec --> Tools[Typed tools + approval policy]
    Tools --> Stream[ExecutionContext.emit chunks]
    Stream --> VM[Agent view model — streamed text]
    Exec --> Check[Checkpoints + replay]
    Exec --> Obs[Tracing + evaluation]
    Zero[ZeroCloudMode guard] --> Prov
```

`MLXLocalProvider` fails closed when MLX is not linked. Streaming commits
completed text as an assistant chat message.
