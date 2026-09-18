# ArchonMemoryProxima

`ArchonMemoryProxima` is an optional dense-index adapter. It wraps ProximaKit
behind ArchonMemory's vendor-neutral `VectorIndex` contract.

It may improve query latency, but it does not replace ArchonMemory's durable
records, scopes, filters, temporal facts, graph, deletion, migration, or
recovery behavior. The adapter is excluded from `ArchonFull` and must not become
the default until the [competitor scorecard](../competitor-comparison.md)
passes recall, latency, memory, persistence, recovery, migration, privacy, and
device gates. First latency/recall evidence — package gate plus iPhone 16
measurements — is recorded in
[`Benchmarks/README.md`](../../../Benchmarks/README.md); memory ceilings are
still open (see below).

## Migration contract

`ProximaVectorIndexAdapter.migrate(from:ceiling:)` rebuilds the index from any
`VectorIndexRebuildSource` (the durable `LocalVectorStore` conforms, returning
non-deleted rows with embeddings in `id` order, batched and cancellable):

- Records the index cannot hold (empty vector, dimension mismatch, non-finite
  component) are skipped and counted in `ProximaMigrationReport.skipped`;
  duplicates fail with typed `VectorIndexError.duplicateID`.
- `ProximaResourceCeiling` is enforced before any write: a record-count or
  projected-snapshot-bytes breach throws a typed error and leaves the
  previously serving index untouched.
- Cancellation (or any rebuild failure) is atomic: rollback is "keep serving
  the old index".
- Only typed `ProximaVectorIndexError`, `VectorIndexError`, `ArchonMemoryError`,
  and `CancellationError` failures escape.

## Recovery contract

`restoreOrRebuild(snapshot:fallback:)` restores a snapshot normally (returns
`false`) or, when the snapshot is missing, corrupt, or dimension-mismatched,
rebuilds from durable truth (returns `true`) under the standard ceiling.
Recovery preserves search results exactly; cancellation propagates without
rebuilding.

## Resource ceilings and snapshot budget

`ProximaResourceCeiling.standard` allows 20,000 records and a 16 MiB snapshot.
Both defaults are conservative placeholders until iPhone-class measurement
lands. Measured snapshot sizes (JSON, 32 dimensions, deterministic `id` order):

| Records | Snapshot bytes | Budget  |
| ------- | -------------: | ------- |
| 500     |       < 512 KB | asserted by `ProximaScaleWorkloadTests` and `ProximaMigrationTests` |

Filtered (allow-listed) search overfetches proportionally to the inverse
selectivity via `LocalVectorStore.filteredOverfetchLimit`, then trims after
exact ranking; the allow-list is never broadened. A 10% allow-list holds
Recall@10 parity (>= 0.99) on the canonical 500-record corpus.

## Still not default: open gates

The adapter stays opt-in. These gates are explicitly open and never faked with
mocks: signed-app, physical-device (memory/thermal/background), live-UI, and
real-model embedding quality. The 10k-device latency/memory ceilings need
iPhone-class measurement before any default flip is considered.
