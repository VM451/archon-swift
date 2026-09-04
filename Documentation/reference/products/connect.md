# ArchonConnect

`ArchonConnect` provides the Archon-owned MCP boundary for tools, resources,
prompts, schemas, progress notifications, cancellation, and HTTP/streamable
HTTP transport.

The official MCP Swift SDK owns wire-level interoperability. Archon retains
typed transport errors, risk classification, schema validation, connection
lifecycle, and host authorization. `MCPHTTPTransport` accepts already-resolved
headers; it never discovers, persists, or prints credentials.

Treat modify, sensitive, destructive, and external tools as side effects. Apply
the host's `MCPPermissionPolicy`, validate arguments before transport, consume
progress when available, and disconnect during host shutdown.
