# Persistence and recovery

Archon separates durable state from request state and from runtime caches. Each
owner has a recovery contract so a process restart cannot silently turn an
active operation into a successful result.

## State ownership

| State | Owner | Recovery behavior |
| --- | --- | --- |
| Agent graph checkpoints | Configured `StateCheckpointer` | Resume, replay, and time-travel behavior depends on the chosen checkpointer |
| Durable memory | `ArchonMemory` GRDB store | Reopen, update, delete, history, and migration are authoritative |
| Vector index | `VectorIndex` adapter | IDs/vectors are replaceable; memory metadata remains in ArchonMemory |
| Model installation | `ModelLibrary` | Staging is validated, then atomically committed |
| Background model transfer | `ModelBackgroundTransferCoordinator` + persistent store | Reconnect with the same URLSession identifier and original request |
| Sandbox workspace sync | `SandboxWorkspace` and sync queue | Offline operations remain queued until the host authorizes sync |
| Request context | `ContextSnapshot` | Ephemeral; never a durable-memory substitute |

## Recovery rules

1. Persist enough identity to reconnect an operation, but do not persist raw
   credentials in transfer records.
2. Revalidate checksums, manifests, permissions, and postconditions after a
   restart; never trust a staged or remote result merely because it exists.
3. Use idempotent cancellation and commit boundaries so a retry cannot produce
   two installed revisions or two successful side effects.
4. Keep optional indexes and caches rebuildable from the authoritative store.
5. Mark interrupted work as failed/resumable when the underlying task no longer
   exists; do not leave it permanently “active.”

Detailed model-transfer behavior is in the [model lifecycle reference](../reference/model-lifecycle.md). Memory-specific workflows are in the
[ArchonMemory DocC catalog](../../Sources/ArchonMemory/Documentation.docc/Articles/GettingStarted.md).
