# Migration audit

This record explains how the unified checkout was formed from the active
sibling package source trees. The sibling repositories remain untouched.

## Initial disposition

| Existing checkout | Disposition in `archon-swift` | Reason |
| --- | --- | --- |
| `archon-agent-swift` | Migrated into `ArchonAgent` | Graph execution and model-policy routing remain package-owned; the legacy model downloader was removed |
| `archon-memory-swift` | Migrated into `ArchonMemory` | Durable memory lifecycle remains local and GRDB-backed |
| `archon-search-swift` | Migrated into `ArchonSearch` | Current-information and research behavior remains behind Archon-owned contracts |
| `archon-sandbox-swift` | Migrated into `ArchonSandbox` | Capability-restricted WebKit mini-app behavior remains local and explicit |
| `archon-router-swift` | Excluded | The router surface was discontinued and is not part of the unified SDK |

## Unified additions

The unified package added `ArchonCore`, `ArchonModels`, `ArchonContext`,
`ArchonConnect`, `ArchonComputerUse`, `ArchonModelsUI`, `ArchonFull`, and the
`archon-model` developer executable. Each product has an independent target
boundary and package tests.

Model lifecycle work includes validated single-file and directory artifacts,
resource integrity, atomic installation, catalog revision checks, resumable
foreground and background transfers, and public Apple runtime adapters.

## Follow-up obligations

- Keep migration behavior documented when a public API or product changes.
- Preserve typed failure behavior at former implicit service boundaries.
- Re-run product-scope and license checks when dependencies move.
- Retain the local-first qualification gate for any future replacement.
- Do not call the migration complete for signed-app, physical-device, live UI,
  or real-model evidence that this package-only checkout cannot provide.

See the [competitor comparison](../reference/competitor-comparison.md) for
current feature decisions and the [release validation guide](../how-to/validate-a-release.md)
for the evidence required before a replacement becomes the default.
