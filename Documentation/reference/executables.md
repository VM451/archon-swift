# Executable reference

The repository ships two executable targets. They are developer and validation
surfaces, not replacements for a signed application target.

## `archon-model`

| Command | Purpose | Important behavior |
| --- | --- | --- |
| `inspect` | Inspect a local file or model directory | Reports detected format and metadata without claiming arbitrary weights are runnable |
| `validate` | Validate a manifest and artifact | Applies the same conservative path, resource, size, checksum, and runtime checks used before install |
| `package` | Copy a validated artifact into a package destination | Refuses to overwrite an existing output |
| `search` | Query a configured model catalog | Network behavior depends on the selected catalog and host credentials |
| `download` | Download a model variant | Uses the model lifecycle contract and staging rules |
| `convert` | Run Apple's `coreai-models` exporter | macOS developer tool; requires caller-supplied checkout and `uv`; experimental output is marked experimental |
| `benchmark` | Measure preparation/unload samples | Accepts validated runnable Core AI or MLX artifacts; never fabricates token throughput |

Conversion is intentionally excluded from application runtime targets. Raw
GGUF, SafeTensors, Transformers, and unknown formats remain
`conversionRequired` until a declared runnable artifact is produced.

## `archon-example-app`

This is a small SwiftUI host for model-library, discovery, storage, download,
App Intents, and Apple Foundation Model availability behavior. Run it on macOS
with:

```bash
swift run archon-example-app
```

iOS and visionOS require a signed Xcode host with the required platform
configuration and entitlements.
