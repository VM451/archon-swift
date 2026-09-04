# Archon model format contract

An `archon-model.json` manifest records the provenance and runtime contract for an installed model:

- original repository and immutable revision
- license metadata and source URL
- runtime and artifact format
- model, tokenizer, checksum, and resource metadata
- supported platforms and minimum OS
- parameter count, precision/quantization, context length, optional KV-cache
  estimate, memory estimate, optional quality/speed estimates, and capabilities

`estimatedQualityScore` is an optional normalized `0...1` catalog value and
`estimatedTokensPerSecond` is an optional expected generation speed. Archon
persists both values without inventing them from a model name; recommendation
uses them only as deterministic tie-breakers after compatibility and fit.

`ArchonModels` distinguishes directly runnable Core AI/MLX artifacts from raw `GGUF`, `SafeTensors`, and Transformers artifacts. Raw artifacts are catalogued as `conversionRequired` and cannot be atomically installed as `Ready` models. Conversion belongs in a developer-side preparation tool; application targets contain no Python or Node conversion runtime.

Catalog discovery is provider-based. `RemoteModelCatalog` can query an HTTP
registry using the same task, runtime, format, compatibility, and limit filters
as local catalogs, and can obtain a bearer token from an injected Keychain-backed
token store. `AppleCoreAIModelCatalog` and `ArchonCompatibleModelCatalog` expose
role-specific wrappers around either static entries or that remote adapter.
`ModelLicensePolicy` lets the consuming app allow known identifiers, require
confirmation for custom identifiers, or deny unknown/missing licenses; when
injected into `ModelDownloadManager`, the policy is enforced before transfer.

The installation path is:

```text
download → staging → size/checksum validation → manifest validation → atomic install → Ready
```

Downloads expose queued, resolving, downloading, paused, verifying,
installing, ready, failed, and cancelled events. Directory variants download
each declared resource independently, preserving partial files for range
resume. Transient HTTP/network failures use the bounded `ModelDownloadPolicy`
retry window; deterministic response, size, checksum, and manifest failures are
not retried. A resumed 206 response must include a `Content-Range` beginning at
the existing staged byte count. `ModelLoadManager` provides explicit prewarm, cancellation, idle
unload, app-background, memory-pressure, and thermal-pressure hooks; the host
application should forward its lifecycle notifications to those hooks.

The foreground manager uses an injected `URLSession` by default and exposes a
`ModelByteStreamProvider` boundary for deterministic host transports and tests.
For OS-managed process-relaunch downloads, `ModelBackgroundTransferCoordinator` owns a
background `URLSessionDownloadDelegate`, persists opaque resume data encrypted
with a Keychain-held key, and reconnects task events to the same
staging/validation/install contract through `ModelDownloadManager`. When the
manager itself is recreated, the host rehydrates the original
`ModelDownloadRequest` through the manager's `resumeInBackground` overload;
transport persistence alone does not contain model metadata needed for final
installation.

The manifest's optional `artifactPath` names the runnable artifact child inside
the managed directory. `modelResources` and `tokenizerResources` are relative
to that artifact root, so directory/bundle artifacts can carry tokenizer and
auxiliary files without flattening them. The validator checks each declared
file's existence, size, checksum, and symlink boundary, and rejects traversal,
absolute paths, duplicates, and directory resources.

The `archon-model convert` command is a macOS developer-tool wrapper around
Apple's `coreai-models` exporter. It requires a caller-supplied checkout and
`uv`, passes through the official platform/compression/experimental/context
options, and moves only the exporter-produced `.aimodel` bundle into the
requested destination. It never runs in an iOS runtime target and fails closed
if the official tool is unavailable.

The `archon-model validate` command performs the same conservative checks before
packaging. `archon-model package` refuses to overwrite an existing output and
copies a validated file or directory artifact as-is. Older manifests without
`artifactPath` remain readable through `InstalledModel`'s compatibility fallback.

`archon-model benchmark` applies the same manifest and artifact validation, then
measures monotonic-clock preparation samples with an unload between samples for
directly runnable Core AI `.aimodel` and MLX `.mlx` artifacts. Use `--artifact`
to supply an artifact when `artifactPath` is absent. Other runtime/format pairs
fail closed until a concrete adapter exists; the command never invents token or
inference-throughput measurements.

`MLXModelRuntimeAdapter` is the concrete runtime-management adapter for
manifests declaring the `mlx` format and runtime. It loads the installed
artifact through MLX Swift on macOS, iOS, and visionOS and releases the cached
container on unload. The package pins the MLX core to the public upstream
revision that fixes the current Xcode Metal address-space diagnostics. If a
consumer removes that runtime dependency, the provider remains API-compatible
but fails closed with `unavailableOnPlatform`; it never pretends that a missing
runtime can execute an MLX artifact.
`CoreAIModelRuntime` uses the public Apple `AIModelAsset` and `AIModel` APIs for
URL-backed Core AI assets. Text generation remains model-specific because
those APIs expose tensor functions, so applications inject a tokenizer and
`CoreAITextGenerationAdapter` that maps the model's real function contract.
