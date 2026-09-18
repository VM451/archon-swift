# ArchonComputerUse

`ArchonComputerUse` coordinates semantic host-app observations and actions. It
does not issue device-wide coordinate events.

## Execution contract

- `ComputerUseObservationProvider` supplies a semantic snapshot.
- `SemanticAction` declares a stable ID, description, target, risk, and
  host-owned execution closure.
- `ComputerUsePermissionPolicy` approves or rejects the risk.
- Observations carry a revision; actions can require a precondition and a
  short-lived `ComputerUseApproval` receipt to prevent stale or unapproved
  execution.
- Targeted actions can verify that the element exists in a fresh snapshot.
- Optional postconditions receive the action result and post-action snapshot.
- Pause, resume, stop, cancellation, stale observations, and verification
  failures remain explicit states/errors.

Accessibility, DOM, App Intents, or another host semantic source should be
preferred. Screenshot/coordinate adapters are fallback integrations and must
add their own approval, stale-state, and audit controls.

## Semantic catalog and App Intent pattern

`ComputerUseCatalog` registers a batch of `SemanticActionDescriptor` values
(ID, description, risk, optional target role, approval flag, postcondition ID)
onto a `ComputerUseController` with one host `execute` closure and a
postcondition-verifier map. Registration is fail-closed per descriptor:
invalid IDs and modify+ descriptors without a resolvable postcondition are
refused (`registerOrThrow` reports `ComputerUseError.invalidDescriptor`).
Hosts bridge App Intents through `ComputerUseAppIntentBridge` (intent ID to
descriptor); unknown intent IDs are skipped, never synthesized. Everything
stays coordinate-free: targeting uses semantic roles and element IDs.

## Approval and postcondition contract

- Risks `.modify`, `.sensitive`, `.destructive`, and `.external` require a
  postcondition (`requiresPostcondition`); `.read` and `.navigate` do not.
- A `targetRole` installs a precondition that fails closed as a stale target
  when no current element carries the role.
- Every execution still requires a valid short-lived `ComputerUseApproval`
  from the `ComputerUsePermissionPolicy`, re-checked after execution, so
  approvals expiring mid-flight fail closed.
- Visual fallback (`requestFallback`) stays default-deny and audited; hosts
  opt in explicitly through the permission policy.
