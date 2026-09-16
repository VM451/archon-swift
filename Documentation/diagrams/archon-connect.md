# ArchonConnect — how it works

`ArchonConnect` owns MCP transport, schema validation, streaming, and
permissions. Archon value types and policy stay in front; the official MCP
Swift SDK backs the `OfficialMCPTransport` adapter behind the
vendor-neutral transport surface.

```mermaid
flowchart TD
    App[App: servers + credentials] --> Perm[Host permissions + risk policy]
    Perm --> Trans{Transport}
    Trans --> Custom[Custom wire transport — current default]
    Trans --> Off[OfficialMCPTransport — official SDK adapter]
    Custom --> Val[Schema validation + normalization]
    Off --> Val
    Val --> Tools[Paginated tools / resources / prompts]
    Tools --> Exec[Tool execution with progress + cancellation]
    Exec --> Out[Structured output + typed errors]
    Disc[Disconnect] --> Cancel[Cancel active SDK contexts + notify]
    Srv[Server-initiated roots / sampling / elicitation] --> Host[Host closures via MCPHostedCapabilities]
    Host --> Out
```

Endpoint policy, auth/header ownership, lifecycle, and error boundaries
remain Archon's. The custom transport stays until full conformance and
production-server lifecycle evidence close. Hosted capabilities install
before `connect()` and advertise exactly what the host implements.
