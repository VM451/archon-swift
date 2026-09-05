# Model catalog reference

`ModelCatalogProvider` is the vendor-neutral discovery contract:

```swift
public protocol ModelCatalogProvider: Sendable {
    var id: String { get }
    func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor]
}

public protocol PaginatedModelCatalogProvider: ModelCatalogProvider {
    func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage
}
```

Catalog discovery is data-driven. User-facing discovery is strict MLX-only:
`MLXModelCatalog` filters every wrapped provider to `.mlx` runtime and format.
The lower-level contracts remain family-neutral for host integrations, and
`AdaptiveModelCatalog.builtIn` retains a small Gemma compatibility seed. For
the complete support statement, read [Supported models and model-family
policy](supported-models.md).

`ModelDescriptor.logoURL` carries optional provider artwork through catalog
filtering and pagination. Providers may omit it; model UI keeps a native
publisher-aware symbol fallback visible when artwork is missing or unavailable.

## Catalog types

| Catalog | Source | Network required by the catalog |
| --- | --- | :---: |
| `StaticModelCatalog` | App- or package-supplied descriptors | No |
| `LocalModelCatalog` | Managed local model directories containing manifests | No |
| `DirectURLModelCatalog` | One caller-supplied artifact URL | Yes when downloaded |
| `AppleCoreAIModelCatalog` | Static Apple entries or an injected HTTP registry | Depends on initializer |
| `ArchonCompatibleModelCatalog` | Static entries or an injected HTTP registry | Depends on initializer |
| `RemoteModelCatalog` | HTTP registry returning model descriptors | Yes |
| `HuggingFaceCatalog` | Hugging Face metadata and repository inventory | Yes |
| `CompositeModelCatalog` | Ordered composition of other catalogs | Inherits its providers |
| `MLXModelCatalog` | Strict MLX-only wrapper around another catalog | Inherits its provider |

Local discovery reads manifests and does not create a download URL. A caller
must import a local artifact through `ModelLibrary.importArtifact(at:manifest:)`
or use the validated download path for a remote variant.

## Search constraints

`ModelSearchRequest` can constrain query, task, runtime, format, compatibility,
device, result limit, variant inclusion, and pagination state. Compatibility
filtering is metadata-driven and should be followed by artifact validation
before load.

`PaginatedModelCatalogProvider.searchPage` is optional so existing custom
catalogs remain source-compatible. Built-in catalogs implement it with a
bounded `ModelCatalogPage`. Offset-based catalogs use `offset`; cursor-based
catalogs return an opaque `nextContinuationToken` that callers pass back
unchanged. Do not request a large limit to simulate pagination.

The request limit is bounded by the API. Callers must handle an empty result;
catalogs are not required to return a preferred model.

`ModelBrowserView` requests one 20-model page when the view or search changes.
It requests the next page only after the user reaches the bottom, shows a real
`ProgressView` while that request is active, and stops when the provider reports
no more results. Search text is lightly debounced so typing does not start one
network request per keystroke.

`ModelBrowserView` and the catalog used for `ModelLibraryView` update checks
automatically wrap their provider in `MLXModelCatalog`. If a host uses the
catalog APIs directly for user-facing discovery, it must apply the same
wrapper:

```swift
let catalog = MLXModelCatalog(provider: HuggingFaceCatalog())
```

`ModelLibrary.installedMLXModels()` and
`ModelLibrary.mlxDiskUsageBytes()` provide the matching installed-library
boundary. `ModelLibraryViewModel`, `ModelLibraryView`, `ModelDetailView`,
`ModelStorageView`, and model App Intents use these APIs, so legacy or
developer-only non-MLX installations do not appear in user-facing model
management.

`compatibleOnly` filters variants using the supplied device snapshot. It can
therefore hide otherwise valid catalog entries on a constrained device; it is
not a model-family filter.

For `HuggingFaceCatalog`, the MLX wrapper also sends `runtime: .mlx` and
`format: .mlx`. That adds the Hub's `mlx` tag filter and prevents popular raw
SafeTensors/Transformers repositories from crowding out directly runnable MLX
results. A raw `HuggingFaceCatalog` can still be used for lower-level metadata
or conversion inspection, but it is not a user-facing discovery catalog.

## Authentication

HTTP catalogs accept an injected `ModelHTTPClient` and optional
`ModelTokenStore`. `KeychainModelTokenStore` is provided for Apple targets, but
the consuming app still owns service naming, access groups, and credential
policy. Catalogs do not print, invent, or silently obtain credentials.

## Provider composition

Use `CompositeModelCatalog` when the application wants deterministic fallback
across curated local entries and explicit remote providers. Keep the ordering
intentional: put offline or app-owned catalogs first when local-first behavior
is required, and do not present a remote result as locally runnable without a
compatible installed artifact.
