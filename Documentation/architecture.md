# Archon architecture

The unified package keeps capability boundaries explicit:

```text
ArchonCore
 ├─ ArchonModels       model catalogs, compatibility, downloads, manifests
 ├─ ArchonContext      request-scoped context assembly
 ├─ ArchonMemory       long-term application-owned memory
 ├─ ArchonSearch       current-information and research pipelines
 ├─ ArchonSandbox      restricted mini-app execution
 ├─ ArchonConnect      MCP transport and permissions
 ├─ ArchonComputerUse  semantic host-app actions and risk controls
 └─ ArchonAgent        graph execution and model-policy routing
```

`ArchonAgent` can ask `ArchonModels` for a deterministic selection, but it does not own model downloads. `ArchonContext` can consume fragments contributed by memory, search, tools, or the host app, but it does not persist them or execute them.

Model catalog roles are composable: static catalogs cover bundled or curated
entries, while `RemoteModelCatalog` provides an HTTP registry adapter with
forwarded search constraints and optional token-store authentication. The
Apple and Archon catalog wrappers can use either source without coupling the
agent to a registry implementation. `ModelDownloadPolicy` bounds retries for
transient HTTP/network failures; integrity and manifest failures remain
deterministic errors. `ModelLoadManager.switchTo` explicitly unloads resident
models before loading the selected model, and its lifecycle hooks expose
prewarm, cancellation, idle unload, memory pressure, app background, and
thermal pressure behavior to the host.

The MCP boundary validates the common JSON Schema subset in-process before
remote tool calls and applies a bounded HTTP request timeout. Computer Use
actions are semantic host actions; optional postconditions can re-observe the
host's semantic tree and reject an action whose intended state was not reached.

The package deliberately excludes the discontinued router target. Remote providers remain an application-selected concern, and local-only policies never fall back to them.

Foreground model transfers use the resumable `ModelDownloadManager`. Hosts
that need OS-managed background transfer can use
`ModelBackgroundTransferCoordinator` with a persistent store and recreate the
coordinator with the same URLSession identifier after relaunch. Background
completion still hands the staged file back to `ModelLibrary` for checksum,
resource, manifest, and atomic-install validation. File-backed transfer state
redacts credential-bearing headers; hosts rehydrate authorization from their
Keychain-backed token service when resuming a paused transfer. After a host
recreates `ModelDownloadManager`, it supplies the original `ModelDownloadRequest`
to `resumeInBackground` so model metadata and installation policy are restored;
the API rejects a request whose variant ID does not match the persisted transfer.
Explicit catalog updates carry the existing installation identity through the
same atomic commit boundary, so a changed catalog variant ID cannot leave the
previous revision installed beside its replacement.

The package is a SwiftPM library family with a buildable SwiftUI example host,
rather than a signed Xcode application target. It therefore exposes
host-integration boundaries for App Intents, lifecycle and memory-pressure
forwarding, semantic Computer Use observations, and OS-managed background
URLSession transfers. Those boundaries are intentionally public and fail closed
until the consuming app supplies its platform objects.
`ArchonModels` App Intents use the same host-registered `ModelLibrary` actor as
the model UI for list, storage, and delete actions; they do not maintain a
second model store.
The same fail-closed rule applies to built-in web/research, sandbox, persistent
memory, and Apple platform services: production defaults do not return
synthetic search results, reports, writes, telemetry, or framework records.
`NativeApplePlatformServices` provides public EventKit, Contacts, MapKit, and
sandboxed-file adapters where the host has granted access; Notes, Mail, battery
telemetry, and timer scheduling remain explicit host-service boundaries. The
consuming app owns the required privacy usage descriptions, entitlements, and
user-facing permission timing.
The installed SDK in this checkout provides public `CoreAI` APIs for URL-backed
asset validation, specialization, function discovery, and cached loading;
`CoreAIModelRuntime` owns that lifecycle. Core AI exposes tensor functions
rather than a universal text-generation contract, so a consuming app must
provide a model-specific tokenizer/text adapter before `CoreAIProvider` can
generate or stream text. Catalog identifiers must be resolved to a bundled or
local asset first.
