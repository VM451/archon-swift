# ArchonMemory

`ArchonMemory` owns application-controlled durable memory and retrieval. Its
local GRDB/SQLite store is authoritative; indexes, summaries, embeddings, and
CloudKit sync are supporting boundaries.

## Main capabilities

- memory add/update/delete, history, scopes, and audit-friendly lifecycle;
- FTS5, vector, filtered, recency/importance, and hybrid retrieval;
- graph entities and relations with temporal validity/supersession;
- document ingestion, chunking, citations, and context retrieval;
- core working-memory blocks separate from durable memory; and
- optional CloudKit synchronization and App Intents/Core Spotlight bridges.

`MemoryExtractionPolicy` bounds automatic candidates and keeps destructive
automatic deletion opt-in. `MemoryRetrievalPolicy` bounds result counts and
controls whether deleted records may be queried. Durable records remain the
source of truth; index adapters must follow the `VectorIndex` update/delete
contract.

Use the [ArchonMemory DocC catalog](../../../Sources/ArchonMemory/Documentation.docc/Articles/GettingStarted.md)
for memory-specific workflows and the [memory comparison](../../../Sources/ArchonMemory/Documentation.docc/Articles/CompetitorComparison.md)
for the competitive feature mapping.
