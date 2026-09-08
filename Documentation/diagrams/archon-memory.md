# ArchonMemory — how it works

`ArchonMemory` owns durable memory and the source-linked competitive research
archive. The consuming app or CLI owns web fetching, provider credentials,
source normalization, and manual refresh. The package validates imported
snapshots, stores canonical source metadata in GRDB, and derives searchable
indexes that can be rebuilt after restart.

```mermaid
flowchart TD
    Host[Consumer app or CLI<br/>web fetch + credentials + normalization + manual refresh] --> Snapshot[CompetitiveResearchSnapshot]
    Snapshot --> Validate[Validate + stale-refresh gate]
    Write[ADD / UPDATE / DELETE / NO_CHANGE] --> Store[(GRDB durable store)]
    Validate --> Store
    Store --> Typed[Typed records<br/>CompetitiveInsight + ProviderProfile + snapshot archive]
    Store --> Graph[Entity graph + temporal validity]
    Store --> Feedback[Local MemoryFeedbackEvent ledger]
    Store --> Derived[Rebuildable derived indexes<br/>KnowledgeBaseIndex + FTS5 + VectorIndex]
    Query[Recall / research query + filters + asOf] --> Hybrid{Hybrid retrieval}
    Hybrid --> Graph
    Hybrid --> Derived
    Graph --> Rank[Rank + exact scope/owner/source filters]
    Derived --> Rank
    Rank --> RAG[RAG answer + citations]
    Store --> Sync{CloudKit opt-in?}
    Sync -->|Container + account OK| Up[Upload pending + apply remote deltas]
    Sync -->|Not configured| Local[Local-only — fail-closed sync]
    Up --> Token[Commit server change token]
    Store --> Exp[JSON export / tombstone-aware forget]
```

The GRDB store is the source of truth. Indexes may hold only IDs and vectors —
never memory metadata or lifecycle state — and are rebuilt from canonical rows
after restart. A stale research import cannot overwrite a newer snapshot,
insight, or provider profile. Retrieval enforces exact owner and scope
filtering, while feedback remains local and is never treated as source
evidence.
