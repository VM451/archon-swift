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

Use the [ArchonMemory DocC catalog](../../../Sources/ArchonMemory/Documentation.docc/Articles/GettingStarted.md)
for memory-specific workflows and the [memory comparison](../../../Sources/ArchonMemory/Documentation.docc/Articles/CompetitorComparison.md)
for the competitive feature mapping.
