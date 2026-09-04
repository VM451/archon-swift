# Benchmarks

The package keeps timing-sensitive checks opt-in so normal CI remains bounded:

```bash
ARCHON_ENABLE_BENCHMARKS=1 swift test --no-parallel -j 2 --disable-sandbox \
  --filter VectorSearchBenchmarkTests
```

That suite measures the real Accelerate-backed vector-search path and enforces
the documented 10,000-item latency SLA. Runtime model benchmarks remain
adapter-owned: `archon-model benchmark path/to/archon-model.json` validates the
manifest and measures actual preparation/unload samples for local Core AI
`.aimodel` and MLX `.mlx` artifacts. Pass `--artifact` when the manifest does
not declare `artifactPath`. Unsupported runtime/format pairs and missing or
invalid artifacts fail closed; the command intentionally reports no synthetic
token throughput.
