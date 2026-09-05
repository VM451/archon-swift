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
user-facing discovery is MLX-only. `ModelDescriptor.family` remains descriptive
data, and a host can register any family whose variant has a truthful MLX
format, resource, capability, license, platform, and memory contract. Core AI,
Foundation Models, cloud, raw, and conversion-required variants are not
returned by the discovery boundary. The bundled Gemma catalog is only a
compatibility convenience; it is not the source of truth for MLX discovery.
