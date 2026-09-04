# Host semantic actions

`ArchonComputerUse` is semantic-first. The host supplies observations and
side-effect closures; Archon coordinates risk checks, stale-state protection,
pause/resume, cancellation, and optional postconditions.

## Define an observation provider

Implement `ComputerUseObservationProvider` using the host's accessibility tree,
DOM, App Intents, or another stable semantic representation. Avoid exposing
coordinate-only actions when a semantic target is available.

## Register a risk-classified action

```swift
import ArchonComputerUse

let controller = ComputerUseController(
    observationProvider: hostObservationProvider,
    permissionPolicy: ReadOnlyComputerUsePolicy()
)

await controller.register(
    SemanticAction(
        id: "open-settings",
        description: "Open settings",
        risk: .navigate,
        targetElementID: "settings-button",
        execute: { await hostOpenSettings() }
    )
)
```

The host must provide an `@Sendable` side-effect closure. Use a custom
`ComputerUsePermissionPolicy` for modify, sensitive, destructive, or external
actions, with explicit user approval where appropriate.

## Require postconditions

Supply `verify` when success means more than the host closure returning. The
controller re-observes after a successful action when observation is available;
verification failure is reported as a typed error.

## Fallback rule

Screenshot or coordinate control is a fallback for hosts without semantic
information. It must be an explicit adapter with approval, stale-observation
detection, cancellation, and audit logging.
