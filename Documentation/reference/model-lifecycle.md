# Model lifecycle reference

`ArchonModels` owns metadata, compatibility, installation, storage, transfer
state, and lifecycle hooks. A runtime adapter owns the framework-specific load
operation.

The lifecycle is model-family neutral. See the [supported model and
model-family policy](supported-models.md) for the difference between a catalog
entry, a runnable artifact, and an app-provided runtime adapter.

## Main actors and boundaries

| API | Responsibility |
| --- | --- |
| `ModelLibrary` | Inspect, import, install, list, update, delete, and measure managed models |
| `ModelDownloadManager` | Foreground download, progress, pause, resume, retry, cancellation, and atomic handoff |
| `ModelBackgroundTransferCoordinator` | OS-managed background URLSession transfer and reconnect after relaunch |
| `ModelLoadManager` | Load, unload, switch, prewarm, idle eviction, memory-pressure, thermal, and background hooks |
| `ModelRuntimeAdapter` | Execute a validated installed artifact through a concrete runtime |
| `ModelLibraryIntentRegistry` | Share the host-registered library with model App Intents and UI |

## Foreground installation

The safe flow is:

1. Search an explicit catalog and inspect the selected variant.
2. Ask the library for a staging location or use the download manager.
3. Stream bytes with cancellation and bounded retry for transient failures.
4. Validate response status, size, checksum, manifest, resources, and license.
5. Atomically install only after all checks pass.
6. Load through a runtime adapter only after compatibility succeeds.

Integrity and manifest failures are deterministic and are not retried.

## Background transfer

For process-relaunch downloads, recreate the coordinator with the same
URLSession identifier and a persistent `ModelBackgroundDownloadStore`, then
call `reconnect()`. The coordinator transfers bytes; `ModelDownloadManager` and
`ModelLibrary` still own request metadata, validation, and installation.

Persisted transfer state must not contain raw credential-bearing headers. The
host rehydrates authorization from its secure credential service when resuming.
If a URLSession task no longer exists, the coordinator reconciles the record to
a resumable failed state instead of leaving it permanently active.

## Runtime lifecycle

Forward application lifecycle and resource pressure to `ModelLoadManager`:

- call `prewarm` only when the model is compatible and capacity is available;
- call `cancelLoad` or unload when the user leaves the model flow;
- unload idle models according to a host-defined age;
- handle app backgrounding, memory pressure, and thermal pressure explicitly;
  and
- use `switchTo` when replacing a resident model so the old runtime is unloaded
  before the new one is loaded.

## Failure posture

The package fails closed for unsupported formats, invalid manifests, checksum
mismatches, incompatible devices, missing runtimes, missing credentials, and
missing host lifecycle objects. It does not report a raw weight file as a
runnable model or silently substitute a cloud provider.
