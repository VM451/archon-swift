# ArchonComputerUse

`ArchonComputerUse` coordinates semantic host-app observations and actions. It
does not issue device-wide coordinate events.

## Execution contract

- `ComputerUseObservationProvider` supplies a semantic snapshot.
- `SemanticAction` declares a stable ID, description, target, risk, and
  host-owned execution closure.
- `ComputerUsePermissionPolicy` approves or rejects the risk.
- Targeted actions can verify that the element exists in a fresh snapshot.
- Optional postconditions receive the action result and post-action snapshot.
- Pause, resume, stop, cancellation, stale observations, and verification
  failures remain explicit states/errors.

Accessibility, DOM, App Intents, or another host semantic source should be
preferred. Screenshot/coordinate adapters are fallback integrations and must
add their own approval, stale-state, and audit controls.
