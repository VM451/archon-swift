# ArchonSandbox — how it works

`ArchonSandbox` owns capability-restricted mini-app execution behind the
provider-neutral `SandboxExecutionProvider` contract. The local adapter is
in-process WebKit — a capability boundary, never claimed as VM-grade
isolation.

```mermaid
flowchart TD
    Req[Bounded execution request] --> Iso[IsolationLevel assignment]
    Iso --> Cap[Deny-by-default capability grant]
    Cap --> WK[Local WebKit adapter: sandbox:// + CSP + nav guards]
    WK --> JS[Document-start JS guards + safe DOM bridge]
    JS --> Run[Execute with quotas + token budget]
    Run --> Audit[Audit events + resource usage]
    Audit --> Res[Bounded result]
    Sync[Workspace sync] --> WK
```

Page-originated host-tool capabilities are required; remote sandboxes may
only arrive as explicit adapters with lifecycle and teardown evidence.
