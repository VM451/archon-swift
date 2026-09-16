# Consuming-App Handoff — Device and Production Gates

Package-only verification is complete (see `context/progress-tracker.md` for
the per-unit evidence). The gates below cannot be proven in this checkout and
must be accepted in a consuming Xcode application with fresh runtime evidence.
Nothing here may be claimed from mocks.

## Device matrix

Run every gate on a representative iPhone, iPad, Mac (Apple Silicon), and
visionOS device or simulator triple. Simulator triple builds are reproducible
via `swift build --target <T> --triple <triple> --sdk $(xcrun --sdk
<iphonesimulator|xrsimulator> --show-sdk-path)`.

## Per-product gates

- **ArchonModels / ArchonAgent** — Real on-device inference per tier: MLX
  generation on iPhone/iPad/Mac, adapter smoke per runtime (MLX, Core AI,
  Foundation Models), adaptive routing under memory pressure, and streaming
  cancellation races on-device. Accept when each tier's smoke passes with
  measured latency.
- **ArchonMemory / ArchonMemoryProxima** — The canonical recall workload at
  iOS scale (same seeded corpus, larger N) with measured Recall@10, p95, and
  memory ceiling; GRDB CloudKit conflict end-to-end. First on-device
  latency/recall evidence exists (see `Benchmarks/README.md`); memory
  ceiling, larger N, and CloudKit conflict are still open. Accept when the
  rubric in `context/quality-scorecard.md` holds on-device before any
  default change.
- **ArchonSearch** — A live politeness run (robots fetch, deny-skip,
  crawl-delay against real hosts), WebKit escalation on JS-heavy pages, and a
  larger real-world extraction corpus. Accept when politeness holds live and
  extraction quality is scored, not asserted.
- **ArchonSandbox** — Live WebKit enforcement of CSP, blocked network, bridge
  bounds, quotas, and cleanup. Accept when the threat-model suite's
  package-level proofs have live counterparts.
- **ArchonConnect** — Production MCP servers (run the reference
  implementations): socket teardown behavior, full conformance, and an OAuth
  authorizer end-to-end. Accept when the D-004 replace/wrap/retain call can be
  revisited with server evidence. The `LoopbackMCPServerTests` hang needs a
  clean-network lane first (pre-existing environmental issue).
- **ArchonComputerUse** — App Intents / Accessibility / DOM observation
  adapters in a signed app, entitlement and permission review, approval UX,
  and the governed visual fallback path. Accept when live interaction,
  pause/resume, and audit capture are demonstrated on-device.
- **ArchonCore / ArchonContext** — Permission prompt flows and the
  per-target Apple-API availability matrix on each OS version. Accept when
  every gated capability shows its real state on-device.
- **ArchonModelsUI / ArchonFull** — UI tests against the
  `archon.models.*` identifier inventory (`context/ui-registry.md`),
  a VoiceOver pass, signed-app import/download/update/delete flows, and
  storage cleanup. Accept when the identifier contract is green live.

## Ownership notes

- Host credentials, entitlements, permissions, and model-family text adapters
  stay in the application boundary (`context/architecture.md`).
- DNS-binding ownership for any networked surface stays with the consuming
  app (`context/dependency-license-inventory.md`).
- No new third-party dependency was added by the win-plan units; the release
  license recheck is a clean re-run, not a new review.
