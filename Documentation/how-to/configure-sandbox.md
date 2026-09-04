# Configure the local WebKit sandbox

`ArchonSandbox` runs a virtual workspace through a WebKit boundary. It is
useful for local mini-apps and controlled HTML/JavaScript execution, but it is
not equivalent to a process, container, or microVM.

## Start with a deny-by-default configuration

```swift
import ArchonSandbox

let workspace = SandboxWorkspace.defaultTemplate(name: "Preview")
let engine = SandboxEngine(workspace: workspace, configuration: .secure)
```

The default capability set denies network, storage, clipboard, camera,
microphone, location, and external URLs. Grant only the permissions required by
the workspace and host policy.

## Bind the host evaluator

The SwiftUI/AppKit/UIKit host binds the platform WebView evaluator to the
actor. Keep that binding on the platform's required actor and treat messages
from the workspace as untrusted input.

## Execute with an explicit isolation claim

```swift
let provider = InProcessWebKitExecutionProvider(engine: engine)
let result = try await provider.execute(
    SandboxExecutionRequest(script: "document.title", timeout: 2)
)
```

Inspect `result.isolationLevel` and `networkAccessPermitted`. A remote
container or microVM must be implemented as a separate provider and disclose
that it is network-dependent.

## Security checklist

- Keep CSP and URL-scheme allowlists restrictive.
- Validate workspace paths and bridge JSON before dispatch.
- Bound message sizes, workspace size, outstanding tool calls, and execution
  time.
- Keep `developerModeEnabled` off in production.
- Audit tool calls, blocked permissions, navigation, and quota failures.
- Test traversal, CSP violations, blocked network, quota exhaustion, and
  cleanup.
