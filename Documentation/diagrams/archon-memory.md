# ArchonMemory — how it works

`ArchonMemory` owns durable memory: fact lifecycle, entity graph,
hybrid graph/vector retrieval, RAG, and optional CloudKit sync. The GRDB
store is the source of truth; dense indexes plug in only through the
vendor-neutral `VectorIndex` seam.

```mermaid
flowchart TD
    Write[ADD / UPDATE / DELETE / NO_CHANGE] --> Store[(GRDB durable store)]
    Store --> Graph[Entity graph + temporal validity]
    Store --> FTS[FTS5 text index — scoped per owner]
    Query[Recall query + MemoryFilter] --> Hybrid{Hybrid retrieval}
    Hybrid --> Graph
    Hybrid --> Vec[VectorIndex seam: IDs + vectors only]
    Graph --> Rank[Rank + filter by owner]
    Vec --> Rank
    Rank --> RAG[RAG answer + citations]
    Store --> Sync{CloudKit opt-in?}
    Sync -->|Container + account OK| Up[Upload pending + apply remote deltas]
    Sync -->|Not configured| Local[Local-only — fail-closed sync]
    Up --> Token[Commit server change token]
    Store --> Exp[JSON export / tombstone-aware forget]
```

Indexes may hold only IDs and vectors — never memory metadata or lifecycle
state. Retrieval enforces exact owner filtering.
