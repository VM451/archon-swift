# Competitive Analysis & Architecture Convergence

ArchonMemory extracts the strongest user outcomes from memory products while
preserving a stricter local-native boundary: the durable memory core runs
in-process through Swift on Apple platforms, and cloud models or CloudKit sync
are explicit host-controlled extensions. This is not a claim that every
competitor feature or every model can run locally.

## How to compare the products

Capability evidence answers whether a product advertises or ships a feature.
Local qualification asks whether the core behavior runs on the user's Apple
device through native Swift/SwiftPM without a required service or separate
local server. Independent user-pull evidence is required before a feature is
called “user-loved.” The full evidence, confidence, and quality gates are in
the [whole-SDK competitor registry](../../../../context/competitor-signature-features.md).

## Signature feature comparison

| Capability | ArchonMemory | Mem0 | Supermemory | Zep | Letta | CrewAI Memory |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Local native Swift core | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Automatic extraction | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ |
| Deduplication / contradiction handling | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ |
| Temporal facts / invalidation | ✅ | ⚠️ | ⚠️ | ✅ | ⚠️ | ⚠️ |
| Working-memory blocks | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ | ⚠️ |
| Scoped hybrid retrieval | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| Profile/context synthesis | ✅ | ⚠️ | ✅ | ⚠️ | ⚠️ | ⚠️ |
| Local persistence / audit | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |

Legend: ✅ available and qualifying · ⚠️ partial or adapter-dependent · ❌ no
local-native equivalent. Detailed capability evidence remains in the
[whole-SDK competitor registry](../../../../context/competitor-signature-features.md).

## ArchonMemory capability map

| Capability | Archon implementation | Boundary and evidence |
| --- | --- | --- |
| Durable facts | GRDB/SQLite-backed `MemoryItem` lifecycle with history and deletion | Application-owned; package tests cover update/delete and reopen behavior |
| Working memory | `CoreMemoryBlock` and `CoreMemoryManager` | Explicitly separate from durable memory and request context |
| Temporal truth | Validity windows, supersession, versions, and graph relations | Must pass contradiction, invalidation, migration, and recovery tests |
| Retrieval | FTS5, dense vectors, filters, recency/importance, and optional `VectorIndex` | `ArchonMemoryProxima` is optional; the durable store remains authoritative |
| Profile/context synthesis | Document ingestion, summaries, provenance, and `ArchonContext` contributors | No implicit inference or source deletion; user scope and audit are explicit |
| Sync | Optional CloudKit boundary | Sync is not required for local operation and remains host/configuration-owned |
| Model support | Apple Foundation Models, Core ML, local MLX, and explicit provider protocols | Credentials and model-family adapters belong to the consuming app |

## Current index evidence

The deterministic [memory/index benchmark](../../../../context/memory-index-benchmark.md)
compares Archon's current vector store, the optional Proxima adapter, and
RecallKit on 2,000- and 10,000-record workloads. On the arm64 macOS package
host, the Proxima adapter reached `Recall@10 = 1.000` at 10,000 records with
`efSearch=256` and `0.73 / 0.75 ms` median/p95 query latency. These are not
iPhone measurements and do not approve replacing the default.

The [quality scorecard](../../../../context/quality-scorecard.md) requires
Recall@10 of at least `0.99`, no worse equivalent p95 latency, bounded memory,
correct persistence/recovery/deletion/migration, no privacy regression, and
consuming-app/device evidence before a replacement becomes the default.

## Design principles

- Reuse Apple frameworks and qualifying Swift packages behind Archon-owned
  contracts; do not copy competitor code or expose vendor types by default.
- Keep extraction, temporal validity, scopes, forgetting, export, audit, and
  durable storage as Archon-owned semantics.
- Keep vectors and indexes replaceable; indexes may store IDs/vectors but not
  Archon lifecycle or permission state.
- Never imply that CloudKit, a cloud model, or a hosted memory service is
  required for the local core.
