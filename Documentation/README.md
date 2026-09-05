# Archon documentation

This directory is the cross-product documentation set for Archon Swift. It is
organized using the Diátaxis model so each document has one job:

| Section | Purpose | Start here when you need to… |
| --- | --- | --- |
| [Tutorials](tutorials/) | Learning-oriented, end-to-end paths | Build your first local model flow |
| [How-to guides](how-to/) | Task-oriented implementation recipes | Integrate a capability into an app |
| [Reference](reference/) | Exact contracts and boundaries | Check supported products, fields, states, or commands |
| [Explanation](explanation/) | Architecture and design rationale | Understand why Archon is shaped this way |
| [Decisions](decisions/) | Historical and migration records | Understand what was retained, replaced, or excluded |

The package's API reference remains in Swift documentation comments and the
DocC catalog under `Sources/*/Documentation.docc`. Published competitive
decisions and release gates live in the [decision framework](reference/decision-framework.md),
[competitor comparison](reference/competitor-comparison.md), and [release
validation guide](how-to/validate-a-release.md). Internal agent working
records are intentionally local-only and are not part of the GitHub
documentation surface.

## Decision vocabulary

| Decision | Meaning in this SDK |
| --- | --- |
| **REUSE** | Existing Apple or Swift capability is sufficient and used directly. |
| **PARTIAL / ADAPT** | Existing capability is useful but Archon adds a vendor-neutral boundary, policy, or lifecycle layer. |
| **BUILD** | Archon owns missing local-native behavior because no qualifying replacement exists. |
| **INSPIRATION** | Cloud, server, or non-native reference used for outcomes and patterns only. |
| **PENDING** | Evidence is incomplete; no adoption or parity claim is made. |

## Recommended reading paths

### New application

1. [Add Archon and choose products](how-to/add-archon.md)
2. [Integrate a local model](tutorials/first-local-model.md)
3. [Understand product boundaries](reference/products.md)
4. [Forward lifecycle and permissions](how-to/host-lifecycle.md)
5. [Read the competitor comparison and scorecard](reference/competitor-comparison.md)

### Existing Archon integration

1. [Local-first boundaries](explanation/local-first-boundaries.md)
2. [Model lifecycle reference](reference/model-lifecycle.md)
3. [Policies and typed failures](reference/policies-and-errors.md)
4. [Release validation](how-to/validate-a-release.md)

### Memory and agent work

Use the product-specific DocC articles for detailed memory workflows:

- [Memory getting started](../Sources/ArchonMemory/Documentation.docc/Articles/GettingStarted.md)
- [Graph memory](../Sources/ArchonMemory/Documentation.docc/Articles/GraphMemoryGuide.md)
- [CloudKit sync](../Sources/ArchonMemory/Documentation.docc/Articles/CloudKitSyncGuide.md)
- [Custom model providers](../Sources/ArchonMemory/Documentation.docc/Articles/CustomLLMProvider.md)
- [Competitive feature comparison](../Sources/ArchonMemory/Documentation.docc/Articles/CompetitorComparison.md)

## Current package boundary

Archon is a SwiftPM package family for iOS, iPadOS, macOS, and visionOS 27
where the underlying Apple capability is available. The repository includes a
buildable macOS SwiftUI example and package-level tests, but not a signed
consuming application. Device, entitlement, permission, live UI, and
model-specific runtime claims must be validated in the consuming app.

## Documentation rules

- Keep one canonical home for each contract; link instead of duplicating text.
- Mark behavior as local, network-dependent, host-supplied, optional, or
  unavailable whenever that distinction affects privacy or correctness.
- Treat public API comments and tests as the contract for signatures and
  failure behavior; update this documentation when those contracts change.
- Keep examples minimal, compilable, credential-free, and safe to paste.
- Do not turn a benchmark observation into a device-wide guarantee.
- Add migration notes when a public path, product, dependency, or default
  changes.
- Run the package verification commands from the root before publishing docs.

See the [competitor comparison and scorecard](reference/competitor-comparison.md)
and [release validation guide](how-to/validate-a-release.md) for the evidence
required before a capability or replacement becomes a default.

The concise product-by-product matrix is in the repository
[README](../README.md#product-decision-matrix).
