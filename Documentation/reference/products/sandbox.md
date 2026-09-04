# ArchonSandbox

`ArchonSandbox` hosts a virtual HTML/CSS/JavaScript/WASM workspace through a
restricted WebKit runtime, with a native bridge for DOM patches, tools, events,
and workspace synchronization.

## Security boundary

`SandboxConfiguration` is deny-by-default for network, storage, clipboard,
camera, microphone, location, and external URLs. CSP, URL-scheme allowlists,
message limits, workspace quotas, path validation, and cancellation remain
active even when developer tooling is enabled.

`InProcessWebKitExecutionProvider` explicitly reports `.inProcessWebKit`. It is
not a process, container, or microVM. Remote isolation belongs in a separate
`SandboxExecutionProvider` adapter and must disclose network dependence.
