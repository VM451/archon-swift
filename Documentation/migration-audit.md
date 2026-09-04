# Initial migration audit

The unified checkout was created from the active sibling package source trees. The original sibling repositories remain untouched.

| Existing checkout | Initial disposition in `archon-swift` |
| --- | --- |
| `archon-agent-swift` | Migrated; depends on `ArchonCore` and `ArchonModels`; legacy model downloader removed; deterministic model-policy routing added |
| `archon-memory-swift` | Migrated and retained as the long-term memory implementation; GRDB remains scoped to this target |
| `archon-search-swift` | Migrated and retained as the current-information/research implementation |
| `archon-sandbox-swift` | Migrated and retained as the capability-restricted mini-app implementation |
| `archon-router-swift` | Excluded; the discontinued router surface is not part of the unified SDK |

The first vertical slice adds `ArchonCore`, `ArchonModels`, `ArchonContext`, `ArchonConnect`, `ArchonComputerUse`, `ArchonModelsUI`, `ArchonFull`, and the `archon-model` developer executable, plus independent package products and tests. `AppleFoundationModelProvider` now delegates to the public Foundation Models runtime with explicit test injection. Model packages now support validated single-file or directory artifacts, resource integrity checks, atomic installation, and catalog revision checks. `CoreAIModelRuntime` now uses the public Core AI asset/runtime APIs for URL-backed validation, specialization, function discovery, caching, and unload; a real consuming application is still required to provide each model family's tokenizer/text adapter and to validate platform UI.
