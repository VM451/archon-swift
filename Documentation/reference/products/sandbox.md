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

Execution results include explicit `IsolationLevel` and bounded resource
usage. Audit sinks may be attached to native bridges for host-observable
patches without weakening the deny-by-default policy.

## Capability matrix

`SandboxConfiguration.allowedPermissions` is the base policy. Optional
`capabilityGrants` narrow it per capability with a `SandboxScope`
(`.session`, `.workspaceFile(path)`, `.scheme(name)`) and an optional
`expiresAt`. Grants never widen the base policy: a scoped check passes only
when the permission is allowed AND a non-expired grant covers the scope.
Without grants, session checks honor the base policy and resource scopes deny
(fail closed). `SandboxEngine.checkCapability(_:scope:)` evaluates a check.

## Audit and outcome semantics

Every capability check emits a `.capabilityDecision` event plus a
`SandboxAuditRecord` pairing the event with an outcome (`allowed`, `denied`,
`error`) and the capability under evaluation. Records flow through
`SandboxEngine.auditStream` (bounded, newest 500) and `auditRecords()`. The
developer overlay audit tab filters by outcome and capability through the
pure, WebKit-free `SandboxAuditFilter`.

## WASM-in-WebKit limits (non-VM disclosure)

`loadWasmModule(_:)` validates a workspace `.wasm` asset (relative path, no
traversal, size within `maxBytes` clamped to a 16 MiB absolute ceiling, valid
`wasm` magic header) and asks page JavaScript to instantiate it inside the
existing in-process WebKit isolation (`.inProcessWebKit`). This is not a VM,
container, or separate process. CSP keeps `'wasm-unsafe-eval'` only while
`enableWebAssembly` is true; the loader refuses to run when the flag is off.
Module bytes never leave the workspace — only a bounded loader script naming
the validated `sandbox://` path is evaluated.
