# Model contract reference

Archon treats model metadata, model artifacts, and model runtimes as separate
contracts. A filename or model name is never enough to claim that an artifact
can execute on a device.

## Manifest

An `archon-model.json` manifest records:

- model identity, name, publisher, source URL, and immutable revision;
- optional catalog artwork URL used by model-management surfaces;
- license metadata and the consuming app's installation decision;
- declared runtime and artifact format;
- artifact, tokenizer, and auxiliary resource metadata;
- checksums and sizes;
- supported platforms, device architectures, minimum OS, and capabilities;
- parameter count, precision, quantization, context length, and optional KV-cache
  and memory estimates; and
- optional quality and speed estimates supplied by the catalog owner.

The manifest is descriptive evidence. `estimatedQualityScore` and
`estimatedTokensPerSecond` are persisted values and deterministic tie-breakers;
Archon does not infer either value from a model name.

## Format and runtime compatibility

| Format | Direct runtime contract | Compatibility behavior |
| --- | --- | --- |
| `.aimodel` / Core AI bundle | Core AI | May be runnable after manifest, resource, and runtime validation |
| `.mlx` | MLX | May be runnable through `MLXModelRuntimeAdapter` when MLX is linked |
| `GGUF` | None in the base artifact contract | `conversionRequired` |
| `SafeTensors` | None in the base artifact contract | `conversionRequired` |
| Transformers files | None in the base artifact contract | `conversionRequired` |
| Unknown | None | `conversionRequired` or rejected during validation |

Raw weights may be inspected through lower-level APIs, but they are not
returned by user-facing MLX discovery and are not installed as `Ready` models.
Conversion is a developer-side concern and must produce a declared runnable
MLX artifact with a validated runtime contract.

## Resource rules

For directory or bundle artifacts:

- `artifactPath` identifies the runnable artifact child;
- `modelResources` and `tokenizerResources` are relative to that artifact root;
- absolute paths, traversal, duplicate resources, directory resources, and
  symlink-boundary escapes are rejected; and
- every declared file is checked for existence, size, and checksum.

## Installation state machine

```text
catalogue → inspect → download/import → staging →
size/checksum validation → manifest validation → atomic install → Ready
```

An incomplete or invalid artifact is never reported as ready. Experimental
exports remain discoverable for developer validation but cannot load until a
validated catalog or manifest result removes the experimental restriction.

See [model lifecycle](model-lifecycle.md) for operations and
[model catalogs](model-catalogs.md) for discovery behavior. See [supported
models and model-family policy](supported-models.md) for the distinction
between lower-level family-neutral catalog support and the user-facing
MLX-only runnable runtime artifact.
