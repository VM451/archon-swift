# ArchonModelsUI

`ArchonModelsUI` provides native SwiftUI surfaces for the same host-registered
`ModelLibrary` used by model App Intents. It includes installed-model library,
discovery, detail, storage, import, and download/update flows.

The views do not create a second database or decide credentials, entitlements,
runtime adapters, or model policy. Register the configured library through
`ModelLibraryIntentRegistry` and inject catalogs/download managers from the
consuming app.

`ModelBrowserView` is an official-publisher MLX-only user-facing surface. It
wraps the injected `ModelCatalogProvider` in `OfficialModelCatalog`, so Core
AI, Foundation Models, cloud, raw, conversion-required, and community-
converted variants are removed before rendering. The host can configure a
`HuggingFaceCatalog`, static, app-owned, remote, or `CompositeModelCatalog`;
the browser applies the official MLX boundary to that provider as described in
the [supported model policy](../supported-models.md). Local imported artifacts
remain a separate installed-library path and are still filtered to runnable
MLX format.

`ModelLibraryView` likewise lists only installed MLX artifacts and rejects
non-MLX imports from its user-facing import flow. Lower-level
`ModelLibrary` APIs remain available for explicit developer-side artifact
inspection and migration work.

`ModelLibraryViewModel`, model detail/storage views, and the model App Intents
use the same installed-MLX boundary. App Intents list, delete, and report
storage for MLX models only; they do not expose legacy Core AI or raw-weight
installations.

Discovery is incremental: the browser requests one bounded page initially,
offers an explicit load-more action, and shows a `ProgressView` only during
that request. Catalog requests are bounded so stalled providers surface an
error instead of leaving the UI in a permanent loading state. Catalogs that
support opaque cursors should implement `PaginatedModelCatalogProvider`;
existing providers remain supported through their bounded `search` method.

Catalog artwork is carried by `ModelDescriptor.logoURL` and persisted in the
managed manifest when a model is downloaded. `ModelLogoView` renders HTTPS
artwork with a native publisher-aware fallback, so unavailable logos do not
remove model identity from browser, detail, library, or storage surfaces.

`ModelLibraryViewModel` is the main-actor presentation boundary for installed
models, compatibility/update state, download progress, offline failures, and
deletion. It delegates storage and transfer lifecycle to `ArchonModels` rather
than starting unstructured work directly in a view.

Validate accessibility, file-import security scope, loading states, failure
states, offline behavior, and physical-device layout in a signed host app.
