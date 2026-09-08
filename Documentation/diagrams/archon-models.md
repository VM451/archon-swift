# ArchonModels — how it works

`ArchonModels` owns the model lifecycle: catalog discovery, format
inspection, device-fit gating, staged downloads, integrity validation,
atomic installation, revisions, storage, and loading hooks.

```mermaid
flowchart TD
    Cat[Catalog: HuggingFace / Remote / Official MLX-only] --> Meta[Metadata + license + format classification]
    Meta --> Gate{Device-fit gate}
    Gate -->|Runtime, OS, arch, peak-memory OK| DL[Staged download: foreground or background transfer]
    Gate -->|Mismatch| Reject[Reject before transfer]
    DL --> Val{Integrity + manifest validation}
    Val -->|Pass| Install[Atomic install into managed storage]
    Val -->|Fail| Retry[Retry / resume / redownload]
    Install --> Rev[Revisions + lifecycle state]
    Rev --> Load[Loading hooks: CoreAIModelRuntime / MLXLocalProvider]
    Files[Files picker / macOS drop import] --> Inspect[Format inspection]
    Inspect -->|Runnable .mlx / .aimodel| Install
    Inspect -->|Raw GGUF / SafeTensors| Conv[Conversion required — no Run action]
```

A runnable artifact without a peak-memory declaration is rejected unless a
bounded estimate can be derived. Download entry points fail before transfer
when the variant cannot run on the current device.
