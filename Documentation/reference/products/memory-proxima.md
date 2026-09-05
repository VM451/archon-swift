# ArchonMemoryProxima

`ArchonMemoryProxima` is an optional dense-index adapter. It wraps ProximaKit
behind ArchonMemory's vendor-neutral `VectorIndex` contract.

It may improve query latency, but it does not replace ArchonMemory's durable
records, scopes, filters, temporal facts, graph, deletion, migration, or
recovery behavior. The adapter is excluded from `ArchonFull` and must not become
the default until the [competitor scorecard](../competitor-comparison.md)
passes recall, latency, memory, persistence, recovery, migration, privacy, and
device gates.
