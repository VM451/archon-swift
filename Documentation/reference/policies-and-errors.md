# Policies and typed failures

Archon uses explicit policy values and typed errors at boundaries where a
silent fallback could violate privacy, safety, or correctness.

## Core policy types

| Type | Important values | Controls |
| --- | --- | --- |
| `ModelPrivacyPolicy` | `localOnly`, `preferLocal`, `appleOnly`, `customLocalOnly`, `cloudAllowed` | Model routing and fallback |
| `SearchNetworkPolicy` | `localOnly`, `networkAllowed` | Whether search may cross the network |
| `IsolationLevel` | `inProcessWebKit`, `localProcess`, `remoteContainer`, `remoteMicroVM` | Sandbox execution claim |
| `ArchonPermission` | network, storage, clipboard, camera, microphone, location, external URL | Sandbox/host capability grants |
| `ComputerUseRisk` | read, navigate, modify, sensitive, destructive, external | Host-action approval |
| `MCPRisk` | read, modify, sensitive, destructive, external | Tool authorization |

## Local-only behavior

`localOnly` is a hard requirement. A local-only search request must identify a
local workspace source and cannot request a live crawl. A local-only model
policy returns an unavailable selection when no compatible local model exists.
No provider may silently switch to a cloud endpoint.

## Typed error expectations

Callers should distinguish at least these classes:

- invalid caller input or budget;
- unavailable platform capability or runtime;
- permission or authorization denial;
- network/transport failure;
- integrity, manifest, or compatibility failure;
- cancellation, timeout, or stopped operation; and
- postcondition or recovery failure.

Errors are part of the contract. Do not catch all errors and turn them into a
successful empty result unless the product API explicitly defines that behavior.
Preserve cancellation and report whether an operation crossed a network or
performed a side effect.

## Host responsibilities

The consuming app owns API keys, Keychain service policy, entitlements, privacy
usage descriptions, App Intents registration, lifecycle forwarding, semantic
observations, and user-facing approval UI. Archon provides the typed boundary;
the host supplies the authority.
