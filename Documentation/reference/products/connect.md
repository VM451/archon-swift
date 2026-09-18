# ArchonConnect

`ArchonConnect` provides the Archon-owned MCP boundary for tools, resources,
prompts, schemas, progress notifications, cancellation, and HTTP/streamable
HTTP transport.

The official MCP Swift SDK owns wire-level interoperability. Archon retains
typed transport errors, risk classification, schema validation, connection
lifecycle, and host authorization. `MCPHTTPTransport` accepts already-resolved
headers; it never discovers, persists, or prints credentials.

Host-provided client capabilities — workspace roots, sampling completions,
and elicitation answers — install through `MCPHostedCapabilities` before
`connect()`, so the initialize handshake advertises exactly what the host
implements. Unset capabilities are never advertised; unhandled
server-initiated requests fail closed. Model inference, UI rendering, and
filesystem access stay in the consuming app.

Treat modify, sensitive, destructive, and external tools as side effects. Apply
the host's `MCPPermissionPolicy`, validate arguments before transport, consume
progress when available, and disconnect during host shutdown.

`MCPClient` can emit redacted `ArchonAuditEvent` values for connection,
disconnection, and tool outcomes. Remote transport is always a host-visible
network boundary; local policy must decide whether it is permitted.

## Package-provable conformance scope

`conformanceProbe()` runs a fake-transport-only report
(`MCPConformanceReport`): pagination cursor-cycle rejection, collection-bound
hits, and forwarded notification methods — zero network, no live server. It
never claims live-server interoperability. The shared `MCPPaginationGuard`
uniformly enforces the 100-page / 1000-item bounds and cursor-cycle rejection
across tools, resources, and prompts list operations. Each
`MCPTransportDescriptor` carries a `conformanceScope` disclosure.

## Transport default and teardown

The custom `MCPHTTPTransport` stays the default until the official-SDK gates
close; `OfficialMCPTransport` is opt-in for SDK-owned wire behavior. The
official adapter forwards only allowlisted server notifications
(`forwardedNotificationMethods`); arbitrary vendor notifications are dropped
at the adapter boundary. Both transports and `MCPClient` offer bounded
`disconnect(timeout:)`: cancel request contexts, finish streams, clear tool
grants, keep hosted capabilities — idempotent and safe to call twice.
