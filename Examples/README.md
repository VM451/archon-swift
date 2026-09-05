# Archon Example App

SwiftUI example target for validating Archon package composition. The
executable can be launched directly on macOS; iOS and visionOS validation
requires embedding the package in a consuming Xcode application.

## Run

```bash
# macOS
swift run archon-example-app
```

`swift run` does not produce a signed iOS or visionOS application. Use an Xcode
host for those platforms so the app can provide its deployment target,
entitlements, privacy usage descriptions, permissions, and lifecycle
forwarding.

## Covers

- installed-model library and storage views;
- Files import and macOS drag-and-drop of compatible model artifacts;
- MLX-only Hugging Face discovery, filters, compatibility, and revision checks.
  The host passes `HuggingFaceCatalog`, and the model browser applies
  `MLXModelCatalog`; additional families appear when the catalog describes
  validated runnable MLX artifacts;
- real download lifecycle: pause, resume, retry, redownload, delete, and select;
- model-library App Intents, discoverable App Shortcuts, and installed-model entity registration;
- Apple Foundation Model chat when the host device supports it; otherwise the
  unavailable state is shown.

## Comparison-ready validation

The example host is intentionally the bridge between package evidence and a
real application boundary. It is the place to compare:

| Scenario | Local-first path | Explicit extension path |
| --- | --- | --- |
| Model selection | Apple Foundation Models, Core ML, or local MLX when compatible | Host-supplied cloud provider with credentials |
| Memory/context | Application-owned ArchonMemory and request-scoped ArchonContext | Optional CloudKit sync or host retrieval adapter |
| Search | Local workspace/offline corpus through `SearchProvider` | Network search/crawl provider with explicit permission |
| Actions | Semantic host actions with risk and postcondition checks | Host-approved remote/browser adapter |
| Sandbox | In-process WebKit with deny-by-default capabilities | Explicit remote container/microVM adapter |

This matrix is a test plan, not a claim that the SwiftPM example is a signed
production app. Follow the [quality scorecard](../context/quality-scorecard.md)
for the consuming-app, accessibility, permission, and physical-device gates.

The example currently demonstrates the model-library and system-model slice of
the SDK. It is not a complete production composition of every Archon product;
memory, search, MCP, sandbox, and Computer Use integrations still require the
host boundaries described in the root README.

## Boundary

This is a SwiftPM example host, not a signed `.app`. The consuming application
still owns credentials, entitlements, privacy usage descriptions, permissions,
and custom model text-generation adapters.

See the [root README](../README.md) for the system design and package map.
See [supported models and model-family policy](../Documentation/reference/supported-models.md)
for the MLX-only discovery/runtime contract and Gemma compatibility explanation.
See the [feature adoption backlog](../context/feature-adoption-backlog.md) for
the whole-SDK implementation sequence.
