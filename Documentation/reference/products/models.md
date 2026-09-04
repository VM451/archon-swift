# ArchonModels

`ArchonModels` owns model metadata and lifecycle: discovery, compatibility,
licensing, staging, integrity validation, installation, managed storage,
updates, and runtime lifecycle hooks.

Read the focused [model contract](../model-contract.md), [catalog reference](../model-catalogs.md), and [lifecycle reference](../model-lifecycle.md).

## Host-owned concerns

The host supplies credentials, model-family tokenizers, text-generation
adapters, App Intents registration, lifecycle forwarding, and the concrete
`ModelRuntimeAdapter`. A catalog result is not a load guarantee.

## Safety boundary

Every import/download crosses staging, size/checksum, manifest, resource,
license, and compatibility checks before atomic installation. Raw weights remain
conversion-required and unsupported runtime/format pairs fail closed.
