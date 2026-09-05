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

Catalog discovery is data-driven and model-family neutral. The package does
not maintain a universal model allow-list. In particular,
`AdaptiveModelCatalog.builtIn` is a small Gemma compatibility seed, while
`ModelBrowserView` displays the catalog provider supplied by the host app. For
the complete support statement and the reason a discovery screen can appear
Gemma-only, read [Supported models and model-family policy](supported-models.md).

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

`compatibleOnly` filters variants using the supplied device snapshot. It can
therefore hide otherwise valid catalog entries on a constrained device; it is
not a model-family filter.

For `HuggingFaceCatalog`, use `runtime: .mlx` when the user is looking for
downloadable local MLX packages. That adds the Hub's `mlx` tag filter and
prevents popular raw SafeTensors/Transformers repositories from crowding out
directly runnable MLX results. Omitting the runtime intentionally performs a
broad artifact search, where raw checkpoints remain visible as
`conversionRequired`.

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
