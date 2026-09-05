# Reference

Reference pages describe stable product boundaries, data contracts, lifecycle
states, policies, and developer commands. API signatures remain in the Swift
doc comments and DocC catalogs.

- [Products](products.md)
- [Product guides](products/README.md)
- [Model contract](model-contract.md)
- [Model catalogs](model-catalogs.md)
- [Supported models and model-family policy](supported-models.md)
- [Model lifecycle](model-lifecycle.md)
- [Policies and typed failures](policies-and-errors.md)
- [Executables](executables.md)
- [Decision framework](decision-framework.md)
- [Competitor comparison and scorecard](competitor-comparison.md)

## Decision summary

| Decision | Meaning | Example |
| --- | --- | --- |
| **REUSE** | Existing local Apple/Swift capability is sufficient | Foundation Models, Core ML, WebKit |
| **PARTIAL / ADAPT** | Existing capability covers part; Archon adds the contract | MLX Swift, ProximaKit, MCP Swift SDK |
| **BUILD** | No qualifying local-native replacement exists | Memory semantics, local search, agent recovery |
| **INSPIRATION** | Hosted or non-native reference; outcome only | Mem0, LangGraph, Tavily, E2B |
| **PENDING** | Evidence is not sufficient for adoption | Unverified candidates or replacements |

See the [full comparison](competitor-comparison.md) for product mappings,
competitor evidence, scores, and qualification gates.

For the concise product verdict, first-action, and release-gate table, see the
repository [product decision matrix](../../README.md#product-decision-matrix).
