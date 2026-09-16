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

The 64-dimensional rows are the original workload. The 384-dimensional rows
use embedding-sized vectors on the same deterministic RNG stream; uniform
384d data is adversarial for ANN (nearly equidistant), so the product gate
uses a clustered corpus that models topic structure.

| Corpus | Dims | Engine | Build (ms) | Query median / p95 (ms) | Recall@10 |
| ---: | ---: | --- | ---: | ---: | ---: |
| 2,000 | 64 | Archon `LocalVectorStore` | 263.53 | 12.52 / 12.67 | 1.000 |
| 2,000 | 64 | `ArchonMemoryProxima`, `efSearch=64` | 601.97 | 0.12 / 0.13 | 1.000 |
| 10,000 | 64 | Archon `LocalVectorStore` | 4,881.96 | 61.97 / 63.07 | 1.000 |
| 10,000 | 64 | `ArchonMemoryProxima`, `efSearch=64` | 3,771.16 | 0.27 / 0.30 | 0.968 |
| 10,000 | 64 | `ArchonMemoryProxima`, `efSearch=256` | 3,760.56 | 0.73 / 0.75 | 1.000 |
| 10,000 | 384 | Archon `LocalVectorStore`, batched blocks | 5,804 | steady p95 9.1 | 1.000 |
| 10,000 | 384 | `ArchonMemoryProxima`, `efSearch=256`, clustered | 60,430 | 5.33 / 5.89 | 1.000 |

The 10k x 384 `LocalVectorStore` row holds the package gate (steady p95
under 20 ms, Recall@10 at least 0.99) and beat Wax 36605ff head-to-head on
the identical workload (Wax: 36.9 s ingest, 12.9 ms steady p95, recall
1.000). Run it with `ARCHON_ENABLE_BENCHMARKS=1 swift test --filter
ArchonMemoryTests.MemorySearchLatencyTests`.

### iPhone 16 device proof

First physical-device evidence (iPhone 16, iOS 27.0, Debug): the same 10k x
384 clustered workload as the package gate, plus USearch @ f91fe5bc on the
identical corpus, queries, and ground truth.

| Engine (device) | Build (ms) | Query median / p95 (ms) | Recall@10 |
| --- | ---: | ---: | ---: |
| `ArchonMemoryProxima`, `efSearch=64` | 47,598 | 0.88 / 0.99 | 1.000 |
| `ArchonMemoryProxima`, `efSearch=128` | 48,493 | 1.82 / 1.90 | 1.000 |
| `ArchonMemoryProxima`, `efSearch=256` | 42,461 | 4.29 / 4.82 | 1.000 |
| USearch, cosine/f32/connectivity-16 | 63,020 | 2.55 / 2.81 | 1.000 |

### Sparse text retrieval

| Corpus | Engine | Build (ms) | Query median / p95 (ms) |
| ---: | --- | ---: | ---: |
| 2,000 | Archon `LocalVectorStore` FTS5 path | 263.53 | 12.62 / 12.90 |
| 2,000 | RecallKit sparse index | 47.62 | 6.72 / 9.12 |
| 10,000 | Archon `LocalVectorStore` FTS5 path | 4,881.96 | 62.46 / 64.25 |
| 10,000 | RecallKit sparse index | 216.23 | 34.04 / 37.49 |

The macOS rows are arm64 Apple Silicon package timings. The iPhone 16 rows
are first physical-device evidence for latency and recall only. The Proxima
adapter stays an optional performance candidate, not the default
replacement: persistence/reopen, crash recovery, memory ceilings, migration,
and filtered update/delete workloads must still pass the [quality
scorecard](../context/quality-scorecard.md) before adoption.

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
