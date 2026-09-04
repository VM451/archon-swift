# Configure network-backed adapters

Network behavior is an application decision. Archon keeps the local core
usable without a network, then exposes explicit provider boundaries for cases
where current web information, hosted models, remote MCP, or remote execution
is required.

## Search

Use a local workspace source with `localOnly` for offline search:

```swift
import ArchonSearch

let localRequest = SearchRequest(
    query: "release notes",
    source: .localWorkspace(directoryPath: workspacePath),
    networkPolicy: .localOnly
)
let localResponse = try await ArchonSearchProvider().search(localRequest)
```

For public web discovery, opt into the boundary and inspect
`SearchResponse.usedNetwork`:

```swift
let webRequest = SearchRequest(
    query: "Swift concurrency",
    source: .duckDuckGo,
    networkPolicy: .networkAllowed
)
let webResponse = try await ArchonSearchProvider().search(webRequest)
```

`localOnly` rejects network sources and rejects a live crawl for a local source.

## Model catalogs

`HuggingFaceCatalog`, `RemoteModelCatalog`, and HTTP-backed role-specific
catalogs are network-dependent. Inject a `ModelHTTPClient` and, when needed, a
`ModelTokenStore`. The host controls whether that request is permitted and
where credentials are stored.

## Remote providers

Cloud LLM providers, hosted search products, remote MCP servers, browser
sessions, and container/microVM sandboxes should conform to Archon-owned
contracts at the application boundary. Keep vendor SDK types and credentials
out of the default public API.

## Audit the boundary

Record the provider ID, policy, endpoint class, and whether the response used
the network. Show the user when a local request is being upgraded to a remote
operation. See [policies and typed failures](../reference/policies-and-errors.md).
