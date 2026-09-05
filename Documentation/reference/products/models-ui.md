# ArchonModelsUI

`ArchonModelsUI` provides native SwiftUI surfaces for the same host-registered
`ModelLibrary` used by model App Intents. It includes installed-model library,
discovery, detail, storage, import, and download/update flows.

The views do not create a second database or decide credentials, entitlements,
runtime adapters, or model policy. Register the configured library through
`ModelLibraryIntentRegistry` and inject catalogs/download managers from the
consuming app.

`ModelBrowserView` renders the injected `ModelCatalogProvider`; it does not
contain a hidden Gemma-only registry or discover model families on its own. A
Gemma-only screen means the host catalog returned only Gemma entries (or that
filters removed the other variants). Configure a `HuggingFaceCatalog`, local,
static, app-owned, remote, or `CompositeModelCatalog` as described in the
[supported model policy](../supported-models.md).

Discovery is incremental: the browser requests one bounded page initially,
loads another page only when the user reaches the bottom, and shows a
`ProgressView` during that request. Catalogs that support opaque cursors should
implement `PaginatedModelCatalogProvider`; existing providers remain supported
through their bounded `search` method.

`ModelLibraryViewModel` is the main-actor presentation boundary for installed
models, compatibility/update state, download progress, offline failures, and
deletion. It delegates storage and transfer lifecycle to `ArchonModels` rather
than starting unstructured work directly in a view.

Validate accessibility, file-import security scope, loading states, failure
states, offline behavior, and physical-device layout in a signed host app.
