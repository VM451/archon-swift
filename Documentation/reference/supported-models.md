# Supported models and model-family policy

## Short answer

Archon is **model-family neutral**, not Gemma-only. A model family such as
Qwen, Mistral, Llama, Phi, Gemma, or a future family can be represented by
Archon's catalog contracts without adding a new family enum or changing the
selection algorithm.

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

## Why Gemma may be the only model shown

`GemmaModelCatalog` is a curated compatibility catalog retained for the
historical convenience APIs. `AdaptiveModelCatalog.builtIn` currently exposes
that small Gemma seed so existing callers keep their default behavior. It is
not the complete Archon model catalog and it is not an allow-list of supported
families.

`ModelBrowserView` also does not discover models by itself. It renders the
`ModelCatalogProvider` supplied by the consuming app. Therefore, a discovery
screen that shows only Gemma usually means that the host supplied the bundled
Gemma seed or another Gemma-only static catalog. It does not mean that
`ArchonModels` or `ArchonAgent` support only Gemma.

To show additional families, supply a catalog containing their descriptors and
variants, or compose the built-in/local/remote providers described in the
[model catalog reference](model-catalogs.md). To use those same models for
adaptive on-device routing, convert the returned descriptors into an
`AdaptiveModelCatalog`.

## Runtime and artifact support

| Model/runtime path | What Archon can represent | Conditions for runnable use |
| --- | --- | --- |
| Apple Foundation Models | Apple's system model on eligible Apple platforms | The host device and OS must provide the framework capability; this is a system-model path, not a Gemma catalog entry. |
| Core AI | Any model family with a declared `.aimodel` or Core AI bundle variant | The export, manifest, resources, runtime, functions, and device fit must validate; the consuming app supplies any model-specific adapter. |
| MLX | Any model family for which a compatible MLX package is catalogued or imported | The variant must declare `.mlx`/MLX, include the required model and tokenizer resources, fit the current memory envelope, and be supported by the linked MLX runtime/model configuration. |
| Explicit remote providers | Provider-specific model identifiers such as OpenAI, Claude, Gemini, or an Ollama endpoint | The consuming app explicitly selects the provider, owns credentials or endpoint policy, and accepts the network boundary. This is not local model discovery. |
| Raw `GGUF`, `SafeTensors`, or Transformers files | Source artifacts can be described and inspected | The base package reports them as `conversionRequired`; developer-side preparation must produce a validated runnable Core AI or MLX artifact before load. |

The discovery data model can describe text, vision, audio, embedding, image
generation, and classification tasks. A particular runtime/provider still has
to implement the requested task and capability; metadata does not create an
inference adapter.

## Supported catalog sources

`ArchonModels` intentionally does not ship a universal, silently changing
model list. The application chooses the catalog source:

- `StaticModelCatalog` for app-owned or release-pinned descriptors;
- `LocalModelCatalog` for validated manifests already in the app's model
  library;
- `HuggingFaceCatalog` for explicit Hugging Face metadata and runnable MLX
  package discovery;
- `AppleCoreAIModelCatalog` for app- or registry-supplied Core AI entries;
- `ArchonCompatibleModelCatalog` or `RemoteModelCatalog` for an explicit
  developer/HTTP registry; and
- `CompositeModelCatalog` for deterministic local, curated, and remote
  composition.

The `ModelBrowserView` should receive the same configured provider that the
application intends users to browse. An empty result is valid, and
`compatibleOnly` can hide catalogued variants that do not fit the current
device. Raw or conversion-required variants may remain visible but must not
have an enabled Run/Use action.

The browser is intentionally incremental: it requests one bounded page on
entry, follows the catalog's offset or opaque continuation token only when the
user reaches the bottom, and displays a loading state while the next page is
being fetched. This keeps a large remote registry out of the initial view
render and memory footprint.

For Hugging Face local-model discovery, request the runtime explicitly:

```swift
let models = try await HuggingFaceCatalog().search(ModelSearchRequest(
    query: "Qwen",
    task: .textGeneration,
    runtime: .mlx,
    compatibleOnly: true,
    device: ArchonDeviceCapabilities.current
))
```

The MLX request uses Hugging Face's `mlx` tag filter and examines the returned
repository inventories before applying the caller's result limit. A search
without a runtime remains a broad artifact search and may therefore surface
raw, conversion-required checkpoints before runnable packages.

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

let catalog = StaticModelCatalog(models: [
    ModelDescriptor(
        id: "qwen3-0.6b",
        name: "Qwen3 0.6B",
        publisher: "Qwen",
        family: "Qwen",
        source: .huggingFace,
        variants: [qwenVariant]
    )
])

let browser = ModelBrowserView(catalog: catalog)
```

For a changing catalog, use `HuggingFaceCatalog`, an app-owned registry, or a
`CompositeModelCatalog`. For adaptive local routing, use the same descriptors:

```swift
import ArchonAgent

let adaptiveCatalog = AdaptiveModelCatalog(descriptors: try await catalog.search(
    ModelSearchRequest(query: "", task: .textGeneration, runtime: .mlx,
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

1. Do not describe Archon as Gemma-only. Describe Gemma as the bundled
   compatibility seed and convenience API.
2. Treat `ModelDescriptor.family` as data. Never add a family switch merely to
   support a new model name.
3. Check the injected `ModelCatalogProvider` before diagnosing a discovery
   problem. The UI cannot show entries that the host catalog did not return.
4. Preserve paginated discovery. Do not replace a bounded page request with a
   large “load everything” query; pass provider continuation tokens through
   unchanged.
5. Distinguish discoverable, conversion-required, device-compatible, and
   runnable states. Do not infer support from a model name or raw file format.
6. For a new local family, register a validated MLX or Core AI variant, then
   use `AdaptiveModelCatalog(descriptors:)` or `AdaptiveModelCandidate` for
   routing. Keep tokenizer/function adapters at the consuming-app boundary.
7. Read this page together with the [model contract](model-contract.md),
   [catalog reference](model-catalogs.md), [lifecycle reference](model-lifecycle.md),
   and [ArchonAgent product guide](products/agent.md).

The package's promise is broad, validated, data-driven model support—not an
unbounded guarantee that every model checkpoint can execute on every Apple
device without preparation.
