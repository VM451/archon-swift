# Archon Swift

Archon is a modular, local-first Swift SDK for native Apple applications. It uses Apple frameworks where they already provide the capability and adds the missing integration layers for models, context, memory, research, tools, sandboxing, and in-app semantic actions.

## Products

```text
ArchonCore          shared primitives and device capabilities
ArchonModels        catalog discovery, compatibility, downloads, manifests, and storage
ArchonAgent         stateful agent graphs and provider orchestration
ArchonContext       request-scoped context assembly
ArchonMemory        long-term application-owned memory
ArchonSearch        current-information and research pipelines
ArchonSandbox       capability-restricted mini-app execution
ArchonConnect       MCP transport, discovery, and permission boundary
ArchonComputerUse   semantic host-app actions with risk controls
ArchonModelsUI      optional SwiftUI model-library view
ArchonFull          convenience re-export of the SDK family
```

Every product is independently adoptable. `ArchonModels` never advertises raw Hugging Face `GGUF` or `SafeTensors` artifacts as directly runnable: those variants are reported as conversion-required until a supported runtime representation is available.

## Model lifecycle

`ArchonModels` provides a provider-based catalog API, including Hugging Face,
Apple/Archon static registries, direct URLs, and local manifest discovery;
Hugging Face metadata/authentication support; deterministic device-fit
analysis; Keychain-backed tokens; resumable range downloads; checksum/size
validation; staged installation; and an `archon-model.json` manifest that
preserves source provenance.

Runnable single-file artifacts and directory/bundle artifacts are supported. Directory packages can declare model and tokenizer resources; the validator checks every declared relative path, size, checksum, and symlink boundary before atomic installation. Installed source revisions can be compared with any catalog provider through `ModelLibrary.checkForUpdates(using:)` without starting a download.

```swift
import ArchonModels

let catalog = HuggingFaceCatalog()
let models = try await catalog.search(ModelSearchRequest(query: "Qwen"))
let device = ArchonDeviceCapabilities.current
let fit = ModelCompatibilityAnalyzer.analyze(variant: models[0].variants[0], device: device)
```

Compatibility is intentionally explicit. `compatible` means the SDK knows the artifact can be loaded by the declared runtime; `conversionRequired`, `unsupportedArchitecture`, `requiresNewerOS`, and `insufficientMemory` are not loadable states.

Catalogs can be static or HTTP-backed. `RemoteModelCatalog` accepts a developer,
Apple, or Archon registry endpoint, forwards search filters, and can resolve a
Keychain-backed bearer token through the injected model-token store. The
`AppleCoreAIModelCatalog` and `ArchonCompatibleModelCatalog` convenience
wrappers accept the same remote provider while preserving their catalog roles.
`ModelLicensePolicy` provides deterministic allowed/confirmation/denied decisions
for known, custom, and missing license identifiers; an injected policy can stop
the download manager before any transfer begins.

Apple Foundation Model execution uses the public `FoundationModels` runtime through
`AppleFoundationModelProvider` and `FoundationModelsRuntime`. If the system model is
unavailable, generation fails with an availability error; the provider does not
synthesize a response. Dynamic Archon tool schemas are rejected until a typed
`FoundationModels.Tool` adapter can preserve their argument contract.

Core AI integration uses Apple's public `CoreAI` APIs when the consuming build
and device provide them. `CoreAIModelRuntime` validates URL-backed
`AIModelAsset` packages, specializes and caches `AIModel`, exposes function
descriptors, and unloads the cached model. Core AI is a tensor/function runtime,
not a universal text-generation API, so `CoreAIProvider` accepts an explicit
`CoreAITextGenerationAdapter` for the model's tokenizer, prompt format,
sampling, KV cache, and output decoding; without that adapter it fails closed
and never returns synthetic inference. Catalog model identifiers must first be
resolved to a bundled or local asset by the consuming application. Hosts can
also pass `CoreAIModelRuntimeAdapter` to `ModelLoadManager` to connect installed
`.aimodel` packages to the same specialization lifecycle.

`ArchonConnect` includes an injectable MCP client plus a JSON-RPC HTTP transport
for initialize, tool/resource discovery, resource reads, and tool calls. Tool
schemas are validated locally, request timeouts are bounded, and risk/permission
policy is enforced before a call reaches the transport. The transport supports
buffered JSON-RPC and streamable-HTTP responses; a consuming app remains
responsible for any long-lived notification/session stream it needs.
`ArchonComputerUse` is semantic and host-app scoped: an action can require an
observed element, can provide a host-defined postcondition verifier against a
fresh semantic snapshot, and the package never emits device-wide coordinate
events. Its controller exposes explicit `start`, `pause`, `resume`, and `stop`
lifecycle operations; a stopped or paused action cannot report a late success
even if a host closure ignores cooperative task cancellation.

`ArchonModelsUI` provides a functional installed-library view and an injectable
catalog browser with Recommended, Downloaded, Apple/Core AI, and Hugging Face
collections plus task, runtime, size, license, publisher, and device-fit
filters. Model detail drives the real download manager, including progress,
pause/resume/cancel/retry/redownload/delete, verification, installation, and
failure states.

`ArchonModels` also exposes optional App Intents for listing installed models,
checking model-library storage, and deleting a selected model. Register the
host's configured `ModelLibrary` with
`await ModelLibraryIntentRegistry.shared.register(...)` during startup; each
intent fails closed until that registration exists.

## Developer model tool

The package also builds an `archon-model` executable for preparation workflows:

```bash
swift run archon-model inspect path/to/archon-model.json
swift run archon-model validate path/to/archon-model.json --artifact path/to/model.aimodel
swift run archon-model package --manifest path/to/archon-model.json --artifact path/to/model.aimodel --output MyModel.archonmodel
swift run archon-model convert Qwen/Qwen3-0.6B --core-ai-models /path/to/coreai-models --output Qwen3.aimodel
swift run archon-model search Qwen
```

`convert` delegates only to Apple's developer-side `coreai-models` exporter;
it requires `uv` and a local checkout and fails closed without them. It never
embeds Python conversion infrastructure in the runtime package. `benchmark`
validates the manifest and measures real model preparation for directly
runnable Core AI `.aimodel` and MLX `.mlx` artifacts; unsupported runtime/format
pairs fail closed rather than producing synthetic throughput.

## Build and test

This checkout is a Swift Package Manager library family, not an Xcode application. Run package verification from this directory:

```bash
swift build -j 2
swift test --no-parallel -j 2 --disable-sandbox
```

The inherited live deep-research integration test is opt-in with
`ARCHON_ENABLE_LIVE_TESTS=1`; default package tests stay offline and bounded.
The performance SLA benchmark is opt-in with
`ARCHON_ENABLE_BENCHMARKS=1` because timing varies with host load.

The package includes a buildable `archon-example-app` SwiftUI host composition
for demonstrating model discovery, compatibility, downloads, installed-model
management, storage actions, and App Intents registration. It is not a signed
Xcode `.app` target; deployment and live UI acceptance still require a
consuming Apple application with the host's credentials, entitlements, privacy
usage descriptions, and model-runtime adapters. The optional SwiftUI product
is source-compiled as part of the package build.

Search and memory persistence are real, but structured memory/research extraction
requires the host to inject a model handler/provider. The default paths fail
closed when no model is available; they do not fabricate extracted fields or
successful writes.

The built-in web search/content, deep-research, sandbox, and persistent-memory
tools also fail closed until the host injects a real service. Apple platform
tools use the same rule. `NativeApplePlatformServices` uses public EventKit for
Calendar and Reminders, Contacts for contact lookup, MapKit for place search
and distance, and sandboxed file access; Notes, Mail, battery telemetry, and
timer scheduling still require explicit host services. Permission denial and
invalid input are surfaced as typed errors. A consuming app must provide the
corresponding privacy usage descriptions and entitlements before requesting
access. Test and preview code can inject deterministic mocks.

Memory App Intents and background maintenance use the actor-backed
`ArchonClientIntentRegistry`; register the host client during startup when
those integrations are enabled.

`ModelDownloadManager` preserves staging files for foreground pause/resume.
For OS-managed background transfer, `ModelBackgroundTransferCoordinator` uses
an Apple background `URLSession`, resume data, connectivity waiting, progress,
cancellation, and a caller-selected persistent `ModelBackgroundDownloadStore`.
Recreate it with the same session identifier after a process relaunch and call
`reconnect()` before observing or controlling the transfer. The coordinator
only transfers bytes; callers must still run `ModelLibrary` verification and
atomic installation before exposing a model as Ready. File-backed stores
redact credential-bearing request headers; after relaunch, pass a replacement
request with fresh Keychain-derived authorization to `resume` when needed.

## Governing rule

Before adding an Archon abstraction, ask whether Apple already solves the problem. Use Apple when it does, build only the missing adapter when it partly does, and report unsupported behavior honestly when no safe adapter exists.
