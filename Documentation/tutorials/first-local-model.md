# Tutorial: inspect and install a local model

This path keeps discovery and compatibility local. It does not require a
network service or a cloud model.

## Before you start

The directory must contain one or more Archon model packages with a valid
`archon-model.json` manifest. Raw `GGUF`, `SafeTensors`, and Transformers files
are source artifacts and require developer-side conversion before they can be
installed as runnable models.

## 1. Discover compatible local models

```swift
import Foundation
import ArchonCore
import ArchonModels

func localModels(in directory: URL) async throws -> [ModelDescriptor] {
    let catalog = LocalModelCatalog(locations: [directory])
    return try await catalog.search(
        ModelSearchRequest(
            query: "",
            compatibleOnly: true,
            device: ArchonDeviceCapabilities.current
        )
    )
}
```

An empty result is valid. Compatibility metadata is a filter, not proof that a
corrupt or incomplete artifact can load.

## 2. Inspect the selected artifact

```swift
let library = ModelLibrary.makeDefault()
let inspection = try await library.inspectArtifact(at: artifactURL)
```

Review the reported format, runtime, manifest status, and resource checks. Do
not infer runtime compatibility from a repository name or file extension alone.

## 3. Import only after validation

```swift
let installed = try await library.importArtifact(at: artifactURL)
```

The library stages and validates the artifact before its atomic install. The
returned `InstalledModel` is the managed identity used by the UI, lifecycle
manager, and runtime adapter.

## 4. Load through an explicit runtime

Provide a `ModelRuntimeAdapter` for the declared runtime, then use
`ModelLoadManager`. If Core AI, MLX, a tokenizer, or a model-specific function
adapter is unavailable, the load must fail closed.

## What this tutorial does not do

It does not convert weights, download from Hugging Face, invent a tokenizer, or
claim that every Apple device supports every model. For those paths, read
[model catalogs](../reference/model-catalogs.md) and [model lifecycle](../reference/model-lifecycle.md).
