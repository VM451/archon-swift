# ArchonComputerUse — how it works

`ArchonComputerUse` is a semantic controller over host-app observations. It
uses semantic actions and postconditions — screen coordinates are never the
primary contract. Host apps supply observations, entitlements, and
permissions.

```mermaid
flowchart TD
    Obs[Host semantic observations] --> Risk[Risk classification]
    Risk --> Appr{Approval required?}
    Appr -->|Yes| Host[Host approval gate]
    Appr -->|No| Exec[Execute semantic action]
    Host -->|Approved| Exec
    Host -->|Denied| Deny[Audited denial]
    Exec --> Post{Postcondition check}
    Post -->|Met| Done[Auditable completion]
    Post -->|Not met| Pause[Pause + report for resume]
```

Pause/resume keeps long-running tasks auditable. Live behavior is validated
only in a signed consuming app.
