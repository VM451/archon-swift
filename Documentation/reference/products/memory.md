# ArchonMemory

`ArchonMemory` owns application-controlled durable memory and retrieval. Its
local GRDB/SQLite store is authoritative; indexes, summaries, embeddings, and
CloudKit sync are supporting boundaries.

## Main capabilities

- memory add/update/delete, history, scopes, and audit-friendly lifecycle;
- FTS5, vector, filtered, recency/importance, and hybrid retrieval;
- graph entities and relations with temporal validity/supersession;
- document ingestion, chunking, citations, and context retrieval;
- typed, source-linked competitive research snapshots, provider profiles, and
  filtered insight retrieval;
- local opt-in feedback events for measuring usefulness without uploading
  memory content;
- core working-memory blocks separate from durable memory; and
- optional CloudKit synchronization and App Intents/Core Spotlight bridges.

`MemoryExtractionPolicy` bounds automatic candidates and keeps destructive
automatic deletion opt-in. `MemoryRetrievalPolicy` bounds result counts and
controls whether deleted records may be queried. Durable records remain the
source of truth; index adapters must follow the `VectorIndex` update/delete
contract.

Vector search scores through batched column-major blocks with a single-gemm
fast path for uniform corpora (mixed dimensions fall back to scalar scoring
without trapping). The benchmark gate holds steady p95 under 20 ms with
Recall@10 at least 0.99 at 10k x 384; see
[`Benchmarks/README.md`](../../../Benchmarks/README.md).

`CompetitiveResearchSnapshot` is imported by a consuming app or CLI that owns
web fetching, credentials, and source normalization. The package validates the
snapshot, persists each insight/profile through the durable document store, and
rehydrates the derived knowledge-base index after restart. Claims are explicitly
confidence-labeled hypotheses; `MemoryFeedbackEvent` is local product feedback,
not source evidence. The bundled `CompetitiveResearchSeed` provides the first
14-provider planning snapshot without performing network requests.

| Reused | Adapted | Built from the ground up |
| --- | --- | --- |
| GRDB/SQLite document rows, `DocumentItem`, `VectorStore`, `KnowledgeBaseIndex`, `RAGRetriever`, configured embeddings, temporal memory fields, `CoreMemoryBlock`, recall, summaries, export, and the `VectorIndex` seam | Durable rehydration, MIME/source/tag/scope filters, hybrid document ranking, workspace-scoped App Intents, bounded limits, private credential boundary, cancellable CloudKit, and migration-safe export | `CompetitiveResearchSnapshot`, `CompetitiveInsight`, `ProviderProfile`, `CompetitiveInsightFilter`, `MemoryFeedbackEvent`, the deterministic 14-provider seed, full snapshot archive, stale-refresh protection, and the local feedback ledger |

The competitor repositories are references, not copied code. AGPL/server
implementations remain outside the SwiftPM core. The package stores validated
research and rebuilds derived retrieval state; the consuming app or CLI owns
web fetching, credentials, source normalization, and manual refresh policy.

Use the [ArchonMemory DocC catalog](../../../Sources/ArchonMemory/Documentation.docc/Articles/GettingStarted.md)
for memory-specific workflows and the [memory comparison](../../../Sources/ArchonMemory/Documentation.docc/Articles/CompetitorComparison.md)
for the competitive feature mapping.
