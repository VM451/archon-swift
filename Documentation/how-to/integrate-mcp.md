# Integrate MCP connectivity

`ArchonConnect` reuses the official MCP Swift SDK for protocol behavior while
keeping Archon-owned transport, risk, typed-error, and host-credential
boundaries.

## Connect to an HTTP server

```swift
import ArchonConnect

let transport = MCPHTTPTransport(
    endpoint: serverURL,
    headers: resolvedHeaders,
    clientName: "MyApp",
    clientVersion: "1.0"
)

try await transport.connect()
let tools = try await transport.listTools()
if let tool = tools.first {
    let result = try await transport.callTool(name: tool.name, arguments: [:])
    _ = result
}
await transport.disconnect()
```

Resolve `resolvedHeaders` in the consuming app. Do not put API keys in the
package, source code, logs, or persisted transport state.

## Apply authorization

Before exposing a tool to an agent, evaluate its `MCPRisk` through the host's
`MCPPermissionPolicy`. Validate arguments against the tool's declared schema
before sending them to the server. Treat modify, sensitive, destructive, and
external tools as side effects requiring an application-defined approval path.

## Consume progress and cancellation

Use `streamTool` when the server supports notifications or progress. Keep the
stream task cancellable, surface transport errors, and disconnect during host
shutdown. Do not convert a disconnected or timed-out operation into a
successful empty result.
