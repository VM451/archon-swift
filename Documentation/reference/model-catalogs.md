# Model catalog reference

`ModelCatalogProvider` is the vendor-neutral discovery contract:

```swift
public protocol ModelCatalogProvider: Sendable {
    var id: String { get }
    func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor]
}
```

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
device, result limit, and variant inclusion. Compatibility filtering is
metadata-driven and should be followed by artifact validation before load.

The request limit is bounded by the API. Callers must handle an empty result;
catalogs are not required to return a preferred model.

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
