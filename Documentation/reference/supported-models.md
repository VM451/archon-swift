# Supported models and model-family policy

## Short answer

Archon's user-facing model discovery is **MLX-only**. A model family such as
Qwen, Mistral, Llama, Phi, Gemma, or a future family may appear only when its
catalogued variant is a runnable MLX package. The package's lower-level model
contracts remain family-neutral for lifecycle and host integration, but users
are never offered Core AI, Foundation Models, cloud providers, or raw
conversion-required checkpoints by the discovery surface.

That does not mean that every checkpoint is automatically runnable. Archon
separates four different questions:

1. Can the model be described by a catalog?
2. Is the artifact in a runnable format for a declared runtime?
3. Does the artifact fit the current platform, memory, context, license, and
   capability requirements?
4. Does the consuming app provide the tokenizer, text-generation, function,
   or other model-specific adapter required by that runtime?

Only a model that passes the applicable checks is offered as runnable. A model
name, repository name, file extension, or family label is never enough.

## What users see

`ModelBrowserView` and the optional catalog used by `ModelLibraryView` wrap
the host provider in `MLXModelCatalog`. That boundary forces `.mlx` runtime
and format constraints, removes non-MLX variants from mixed descriptors, and
keeps pagination opaque while it skips non-MLX pages. A Core AI, Foundation
Models, remote-only, raw, or conversion-required entry therefore cannot reach
the user through these package UI paths.

`GemmaModelCatalog` remains only as a compatibility convenience for existing
provider APIs. It is not the discovery source and it does not restrict MLX
discovery to Gemma. To offer Qwen, Mistral, Llama, Phi, or another family,
catalogue its validated MLX variant and pass the catalog to the browser.

## Runtime and artifact support

| Model/runtime path | What Archon can represent | Conditions for runnable use |
| --- | --- | --- |
| MLX | Any model family for which a compatible MLX package is catalogued or imported | The variant must declare `.mlx`/MLX, include the required model and tokenizer resources, fit the current memory envelope, and be supported by the linked MLX runtime/model configuration. |
| Core AI, Foundation Models, or remote providers | Lower-level adapters remain available for explicit host integrations | These paths are not returned by the user-facing model-discovery boundary. |
| Raw `GGUF`, `SafeTensors`, or Transformers files | Source artifacts can be described and inspected by lower-level APIs | They are never shown by MLX discovery; developer-side preparation must produce a validated runnable MLX artifact before load. |

The discovery data model can describe text, vision, audio, embedding, image
generation, and classification tasks. A particular runtime/provider still has
to implement the requested task and capability; metadata does not create an
inference adapter.

## Supported catalog sources

`ArchonModels` intentionally does not ship a universal, silently changing
model list. The application chooses the source, then uses the strict MLX
boundary for user-facing discovery:

- `StaticModelCatalog` for app-owned or release-pinned descriptors;
- `LocalModelCatalog` for validated manifests already in the app's model
  library;
- `HuggingFaceCatalog` for explicit Hugging Face metadata and runnable MLX
  package discovery;
- `AppleCoreAIModelCatalog`, `ArchonCompatibleModelCatalog`, or
  `RemoteModelCatalog` for lower-level explicit host integrations; and
- `CompositeModelCatalog` for deterministic local, curated, and remote
  composition before it is wrapped by `MLXModelCatalog`.

For example:

```swift
let browserCatalog = MLXModelCatalog(
    provider: HuggingFaceCatalog(tokenStore: KeychainModelTokenStore())
)
let browser = ModelBrowserView(catalog: browserCatalog)
```

The `ModelBrowserView` should receive the same configured provider that the
application intends users to browse. An empty result is valid, and
`compatibleOnly` can hide catalogued variants that do not fit the current
device. The browser's MLX boundary omits every non-MLX and
conversion-required variant before rendering; those entries are available only
through lower-level developer APIs.

The browser is intentionally incremental: it requests one bounded page on
entry, follows the catalog's offset or opaque continuation token only when the
user reaches the bottom, and displays a loading state while the next page is
being fetched. This keeps a large remote registry out of the initial view
render and memory footprint.

For direct catalog use, request the runtime and format explicitly as well as
using `MLXModelCatalog`:

```swift
let models = try await MLXModelCatalog(provider: HuggingFaceCatalog()).search(ModelSearchRequest(
    query: "Qwen",
    task: .textGeneration,
    runtime: .mlx,
    format: .mlx,
    compatibleOnly: true,
    device: ArchonDeviceCapabilities.current
))
```

The MLX request uses Hugging Face's `mlx` tag filter and examines the returned
repository inventories before applying the caller's result limit. Calling the
strict wrapper is required for user-facing discovery; a raw
`HuggingFaceCatalog` remains a lower-level metadata/conversion API and may
surface non-MLX artifacts when used directly.

## Example: discover more than Gemma

For a host-owned catalog, add any family as data. No new model-family code is
required:

```swift
import ArchonModels
import ArchonModelsUI

let qwenVariant = ModelVariant(
    id: "qwen3-0.6b-mlx",
    name: "Qwen3 0.6B 4-bit",
    modelID: "mlx-community/Qwen3-0.6B-4bit",
    source: .huggingFace,
    format: .mlx,
    runtime: .mlx,
    contextLength: 8_192,
    sizeBytes: 600 * 1024 * 1024,
    estimatedMemoryBytes: 400 * 1024 * 1024
)

let catalog = MLXModelCatalog(provider: StaticModelCatalog(models: [
    ModelDescriptor(
        id: "qwen3-0.6b",
        name: "Qwen3 0.6B",
        publisher: "Qwen",
        family: "Qwen",
        source: .huggingFace,
        variants: [qwenVariant]
    )
]))

let browser = ModelBrowserView(catalog: catalog)
```

For a changing catalog, wrap `HuggingFaceCatalog`, an app-owned registry, or a
`CompositeModelCatalog` in `MLXModelCatalog`. For adaptive local routing, use
the same descriptors:

```swift
import ArchonAgent

let adaptiveCatalog = AdaptiveModelCatalog(descriptors: try await catalog.search(
    ModelSearchRequest(query: "", task: .textGeneration, runtime: .mlx, format: .mlx,
                       includeVariants: true)
))
let provider = ArchonAI.adaptive(
    preference: .adaptive,
    runtime: .preferMLX,
    catalog: adaptiveCatalog
)
```

The memory estimate, resources, license, platform, context, and capability
metadata must be truthful. Adaptive selection fails closed when a candidate is
missing a safe peak-memory estimate or does not fit the current device.

## Guidance for AI agents

When answering questions or changing an application that uses this package:

1. Describe user-facing discovery as MLX-only. Gemma is only a bundled
   compatibility convenience, not the discovery allow-list.
2. Treat `ModelDescriptor.family` as data. Never add a family switch merely to
   support a new model name.
3. Ensure user-facing catalogs are wrapped in `MLXModelCatalog`; the UI cannot
   show entries that the host catalog did not return, and the wrapper removes
   every non-MLX variant.
4. Preserve paginated discovery. Do not replace a bounded page request with a
   large “load everything” query; pass provider continuation tokens through
   unchanged.
5. Distinguish discoverable, conversion-required, device-compatible, and
   runnable states. Do not infer support from a model name or raw file format.
6. For a new local family, register a validated MLX variant, then use
   `AdaptiveModelCatalog(descriptors:)` or `AdaptiveModelCandidate` for
   routing. Keep tokenizer/function adapters at the consuming-app boundary.
7. Read this page together with the [model contract](model-contract.md),
   [catalog reference](model-catalogs.md), [lifecycle reference](model-lifecycle.md),
   and [ArchonAgent product guide](products/agent.md).

The package's user promise is validated, data-driven MLX model discovery—not
an unbounded guarantee that every model checkpoint can execute on every Apple
device without preparation.

## iOS 27 iPhone guidance

Apple lists every iPhone 11 through iPhone 17 model below as compatible with
[iOS 27](https://www.apple.com/os/ios/). OS compatibility is not a model-size
guarantee: storage determines whether an artifact can be retained, while
Archon requires its declared **peak runtime memory** to fit the current process
budget before download or load.

| iPhone generation | Included models | Archon starting point |
| --- | --- | --- |
| 11 | 11, 11 Pro, 11 Pro Max | Use a compact catalogued MLX model with a peak estimate under the live device budget. |
| 12 | 12 mini, 12, 12 Pro, 12 Pro Max | Use the same live peak-memory gate; Pro and non-Pro variants are not interchangeable. |
| 13 | 13 mini, 13, 13 Pro, 13 Pro Max | Use the same live peak-memory gate; do not infer fit from the model name. |
| 14 | 14, 14 Plus, 14 Pro, 14 Pro Max | Choose only variants that publish a peak-memory estimate and pass the current budget. |
| 15 | 15, 15 Plus, 15 Pro, 15 Pro Max | Prefer Apple Foundation Models where the host reports them available; custom MLX remains separately gated. |
| 16 | 16, 16 Plus, 16 Pro, 16 Pro Max, 16e | Custom MLX downloads remain gated by peak memory, not free storage. |
| 17 | 17, 17 Pro, 17 Pro Max, 17e, iPhone Air | Same rule. `DeviceHardwareProfile.iPhone17Pro` is a conservative 12 GB test fixture, not a production entitlement to a 7B/8B model. |

The supplied `DeviceHardwareProfile.iPhone17Pro` fixture has a 12 GB physical
memory profile but retains the package's 3 GiB mobile process envelope and
roughly 1.5 GiB safe model budget. This is deliberately more conservative than
the phone's storage capacity. A host may only revise that envelope after it has
captured representative signed-app memory, thermal, and inference evidence.
