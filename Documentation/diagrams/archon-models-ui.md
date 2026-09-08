# ArchonModelsUI — how it works

`ArchonModelsUI` is the optional embeddable SwiftUI surface for model
discovery and library management. It consumes injected `ModelLibrary`,
catalog, device, and download-manager instances — it owns no store itself.
User-facing discovery is official-publisher MLX-only via
`OfficialModelCatalog`.

```mermaid
flowchart TD
    Entry[ModelBrowserView: entry] --> Page[One bounded catalog page]
    Page --> Filter[Official MLX-only filter: runtime + namespace]
    Filter --> List[Rows: compatibility state + primary action]
    List --> Scroll{Scroll boundary?}
    Scroll -->|Yes| Page
    Scroll -->|No| Detail[ModelDetailView: metadata + variants + license]
    Detail --> DLAct[Download / pause / resume / retry / delete]
    DLAct --> Stream[Real async progress events]
    Stream --> Lib[ModelLibraryView: installed + updates]
    Lib --> Storage[ModelStorageView: disk usage]
    Raw[Raw / community artifact] --> NoRun[Conversion required — no Run action]
```

All views use semantic colors/materials and adapt to Light/Dark mode. No
hard-coded hex colors.
