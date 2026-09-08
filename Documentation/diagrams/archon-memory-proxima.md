# ArchonMemoryProxima — how it works

`ArchonMemoryProxima` is an optional dense-vector adapter that composes
ProximaKit behind `ArchonMemory`'s vendor-neutral `VectorIndex` seam. It is
excluded from `ArchonFull` until persistence, recovery, and device-scale
gates close.

```mermaid
flowchart TD
    Mem[ArchonMemory durable store] --> Upsert[Upsert IDs + vectors]
    Upsert --> Adapter[ProximaVectorIndexAdapter]
    Adapter --> Prox[ProximaKit HNSW index — local, in-process]
    Q[Vector query + allow-list filter] --> Adapter
    Adapter --> Hits[Normalized similarity matches]
    Hits --> Mem2[ArchonMemory ranks against durable records]
    Rebuild[Atomic rebuild] --> Adapter
```

No ProximaKit type enters Archon's public API. Durable records, filtering,
history, and recovery stay owned by `ArchonMemory`.
