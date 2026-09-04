# Archon Benchmarks

Timing-sensitive checks are opt-in so normal builds and CI remain bounded.

## Run

```bash
ARCHON_ENABLE_BENCHMARKS=1 swift test --no-parallel -j 2 --disable-sandbox \
  --filter VectorSearchBenchmarkTests
```

## Measures

`VectorSearchBenchmarkTests` exercises the real Accelerate-backed vector search
path and checks the documented 10,000-item latency SLA.

The developer command measures real preparation/unload samples for local Core
AI `.aimodel` and MLX `.mlx` artifacts:

```bash
swift run archon-model benchmark path/to/archon-model.json --artifact path/to/model.aimodel
```

Unsupported runtime/format pairs, missing artifacts, and invalid manifests fail
closed. The package does not report synthetic token throughput.

See the [root README](../README.md) for package boundaries and test commands.
