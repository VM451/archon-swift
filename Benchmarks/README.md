# Archon Benchmarks

Timing-sensitive checks are opt-in so normal builds and CI remain bounded.

## Run

```bash
ARCHON_ENABLE_BENCHMARKS=1 swift test --no-parallel -j 2 --disable-sandbox \
  --filter VectorSearchBenchmarkTests
```

## Measures

`VectorSearchBenchmarkTests` exercises the real Accelerate-backed cosine
similarity kernel used by Archon's vector path and checks the documented
10,000-item latency SLA. It is a focused kernel check, not a substitute for the
full index comparison below.

The current competitive index comparison is recorded in
[`context/memory-index-benchmark.md`](../context/memory-index-benchmark.md). It
uses the same deterministic workload across Archon's current vector store, the
optional `ArchonMemoryProxima` adapter, and RecallKit's sparse index. Dense
vector and sparse text rows are separate workloads and should not be compared
as if they measured the same ranking operation.

### Dense vector retrieval

| Corpus | Engine | Build (ms) | Query median / p95 (ms) | Recall@10 |
| ---: | --- | ---: | ---: | ---: |
| 2,000 | Archon `LocalVectorStore` | 263.53 | 12.52 / 12.67 | 1.000 |
| 2,000 | `ArchonMemoryProxima`, `efSearch=64` | 601.97 | 0.12 / 0.13 | 1.000 |
| 10,000 | Archon `LocalVectorStore` | 4,881.96 | 61.97 / 63.07 | 1.000 |
| 10,000 | `ArchonMemoryProxima`, `efSearch=64` | 3,771.16 | 0.27 / 0.30 | 0.968 |
| 10,000 | `ArchonMemoryProxima`, `efSearch=256` | 3,760.56 | 0.73 / 0.75 | 1.000 |

### Sparse text retrieval

| Corpus | Engine | Build (ms) | Query median / p95 (ms) |
| ---: | --- | ---: | ---: |
| 2,000 | Archon `LocalVectorStore` FTS5 path | 263.53 | 12.62 / 12.90 |
| 2,000 | RecallKit sparse index | 47.62 | 6.72 / 9.12 |
| 10,000 | Archon `LocalVectorStore` FTS5 path | 4,881.96 | 62.46 / 64.25 |
| 10,000 | RecallKit sparse index | 216.23 | 34.04 / 37.49 |

These are arm64 Apple Silicon macOS package timings, not iPhone or iPad
measurements. The Proxima adapter is therefore an optional performance
candidate, not the default replacement. Persistence/reopen, crash recovery,
memory ceilings, migration, filtered update/delete workloads, and representative
iOS measurements must pass the [quality scorecard](../context/quality-scorecard.md)
before adoption.

The developer command measures real preparation/unload samples for local Core
AI `.aimodel` and MLX `.mlx` artifacts:

```bash
swift run archon-model benchmark path/to/archon-model.json --artifact path/to/model.aimodel
```

Unsupported runtime/format pairs, missing artifacts, and invalid manifests fail
closed. The package does not report synthetic token throughput.

See the [root README](../README.md) for package boundaries and test commands.
See the [competitor registry](../context/competitor-signature-features.md) for
the feature-level comparison and local/native qualification decisions.
