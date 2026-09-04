# Architecture documentation

This compatibility page remains at the original path for existing links. The
architecture is now maintained as focused documents rather than one mixed
overview:

- [System architecture](explanation/architecture.md) — product graph, ownership,
  request flow, and evidence boundaries.
- [Dependency ownership](explanation/dependency-ownership.md) — direct
  dependencies, reuse rules, and public API hygiene.
- [Local-first boundaries](explanation/local-first-boundaries.md) — what
  “local” means and how network/remote behavior is disclosed.
- [Persistence and recovery](explanation/persistence-and-recovery.md) — durable
  state ownership, restart behavior, and idempotent boundaries.
- [Product reference](reference/products.md) — importable products and
  executable targets.

The [documentation index](README.md) explains the documentation taxonomy and
the recommended reading paths.
