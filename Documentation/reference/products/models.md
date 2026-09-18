# ArchonModels

`ArchonModels` owns model metadata and lifecycle: discovery, compatibility,
licensing, staging, integrity validation, installation, managed storage,
updates, and runtime lifecycle hooks.

Read the focused [supported model policy](../supported-models.md), [model contract](../model-contract.md), [catalog reference](../model-catalogs.md), and [lifecycle reference](../model-lifecycle.md).

## Host-owned concerns

The host supplies credentials, model-family tokenizers, text-generation
adapters, App Intents registration, lifecycle forwarding, and the concrete
`ModelRuntimeAdapter`. A catalog result is not a load guarantee.

## Safety boundary

Every import/download crosses staging, size/checksum, manifest, resource,
license, and compatibility checks before atomic installation. Raw weights remain
conversion-required and unsupported runtime/format pairs fail closed.

`ModelRuntimeCapabilities` and `ModelCapabilityRequirements` negotiate task,
streaming, tool-calling, and structured-output requirements before loading.
The lifecycle retains lower-level runtime-neutral contracts, but the package's
user-facing browsing is official-publisher MLX-only. `ModelDescriptor.family`
remains descriptive data, and a host can register any family whose first-party
variant has a truthful MLX format, resource, capability, license, platform, and
memory contract. Core AI, Foundation Models, cloud, raw, conversion-required,
and community-converted variants are not returned by the browsing boundary.
The bundled Gemma catalog is only a compatibility convenience; it is not the
source of truth for official discovery.

## Preparation recipes

`ModelPrepRecipeIndex` maps raw GGUF, SafeTensors, and Transformers sources
to developer-side MLX/Core AI preparation steps. Recipes are data plus
documentation: lookup is fail-closed (unknown families and runnable sources
return nil), and the runtime still rejects raw weights through
`ModelCompatibilityAnalyzer`, `ModelArtifactInspector.isRunnable`, and
`MLXModelCatalog`.

## Download attempts and storage analytics

`ModelDownloadState` carries `ModelDownloadAttempt` snapshots (try count
against the bounded policy cap, resume offsets, delta-reused bytes) on its
downloading, paused, and failed cases. `ModelBackgroundDownloadRecord`
persists the same bookkeeping with truncated errors and capped resume blobs.
`ModelLibrary.storageBreakdown()` reports per-model bytes plus the
staging/temporary split.

## Measured family benchmarks

`ModelFamilyBenchmark` records carry measured quality/speed with explicit
provenance. `recommendedVariant(for:device:task:benchmarks:)` consumes them
after fit, filling in only when a variant has no declared estimate. Invalid
records are ignored; Archon never invents scores.
