## Goal

Upgrade every Archon product so the ecosystem wins its category on the user's own device (iPhone, iPad, Mac, visionOS): on-device compute and data by default, no Archon-operated cloud, no required developer hosting. Each product gets an explicit reuse / adapt / build verdict that reuses or partially adapts qualifying Apple and Swift capabilities and builds only proven gaps.

## Success Criteria

- Every product closes its open package-level gates and holds or raises its engineering score (`Documentation/reference/competitor-comparison.md:436-464`): Proxima 73 to 85+, ModelsUI 81 to 88+, Connect 88 to 92+, ComputerUse 89 to 92+ with confidence raised to Medium; the 91 to 93 products defend their scores with closed recovery, lifecycle, and conformance gates.
- Memory meets the replacement rubric before any default-index change: canonical-workload Recall@10 of at least 0.99, p95 no worse than the current default, bounded memory, correct reopen/delete/migration (`context/quality-scorecard.md:140-158`).
- Agent crash/reopen resumes without duplicating idempotent tool effects; replay and fork are deterministic (`context/quality-scorecard.md:112-121`).
- Search returns local results with the network denied and every remote result carries provider and network metadata with verifiable citations (`context/quality-scorecard.md:84-97`).
- Connect reaches an explicit replace/wrap/retain decision on the official MCP transport with conformance evidence; until then the custom transport stays (`context/dependency-decision-log.md:42-69`).
- The full package suite, product-scope checker, license checker, and scorecard checker stay green, and no new third-party dependency enters the graph without a probe, benchmark, and decision record (`context/dependency-decision-log.md:91-99`).

## Context And Current Facts

- The package owns 12 library products plus the `archon-model` CLI and example app; the graph is acyclic and `ArchonFull` excludes the optional Proxima adapter (`Package.swift:13-28`, `Package.swift:142-158`, `context/architecture.md:17-33`).
- The last full verification passed 657 tests with `LoopbackMCPServerTests` skipped; that hang reproduces on the pristine base and is environmental, not a regression (`context/progress-tracker.md:1406-1412`). CI runs `swift build -j 2`, a skipped-agent/connect test pass, and the three checkers (`.github/workflows/ci.yml:139-158`).
- Strategy source of truth already exists: the signature registry (`context/competitor-signature-features.md`), adoption backlog with Waves A to D (`context/feature-adoption-backlog.md:63-95`), quality scorecard and gates (`context/quality-scorecard.md`), ownership matrix (`context/capability-ownership-matrix.md:61-75`), candidate probes (`context/native-candidate-audit.md:35-47`), agent comparison (`context/agent-candidate-comparison.md:15-23`), and the memory/index benchmark (`context/memory-index-benchmark.md:34-42`).
- Recent wins to defend: ranked search with local rerank, freshness, registry fan-out, and Apple `NLEmbedding` semantic boost with no new dependencies (`context/progress-tracker.md:1414-1432`); Group 1 to 5 hardening across agent runtimes, models lifecycle, core/context, memory/search, and sandbox/connect/computer-use/UI (`context/progress-tracker.md:1376-1412`).
- Evidence map for this plan: every named reuse candidate and competitor outcome below traces to workspace evidence inspected in this run (matrix, audit, backlog, scorecard, benchmark, decision log). No new external dependency is proposed, so no external research was required; there is deliberately no Sources section.

## Constraints And Non-goals

- User principle: everything runs on the user's device. No cloud hosting, no custom developer hosting. Local in-process Swift is the default execution and data plane (D-014, `context/dependency-decision-log.md:187-197`).
- A capability counts as existing only if it runs on-device, embeds in-process through Swift/SwiftPM, and needs no cloud service or separate local server (D-001, `context/dependency-decision-log.md:12-20`). Cloud, localhost-server, and non-Swift systems are feature references or explicit optional adapters only.
- Engineering rules: Swift 6 strict concurrency, actors, `Sendable`, typed errors, structured cancellation, fail-closed defaults, vendor-neutral public APIs, target-scoped dependencies, deterministic Swift Testing suites per product (`context/code-standards.md`, `context/capability-ownership-matrix.md:126-145`).
- Non-goals: whole-web index parity (hosted scale is physically unbeatable on-device; Archon wins on privacy, latency, offline behavior, and cost instead, per D-013 outcomes-not-clones); VM-grade isolation claims for WebKit; copying competitor code, prompts, or data; proving signed-app, physical-device, live-UI, or real-model behavior inside this package-only checkout (D-008).

## Key Decisions

- KD1: on-device means compute and data live on the device. Explicit, user-consented client fetching of public web content (browser-like) is allowed for live search and stays observable; it is never an Archon-operated service and never the default (D-014; SEARCH-001 local-first, `context/feature-adoption-backlog.md:48-49`). If the user wants strict-offline instead, see Open Questions.
- KD2: per-product verdicts follow the ownership matrix and backlog; partial adapt is the default and full builds are limited to proven gaps:

| Product | Verdict | Reuse / adapt source | Build gap |
|---|---|---|---|
| Core | REUSE+BUILD | Apple frameworks | availability matrix |
| Models | ADAPT | MLX, HF, FM adapters | routing, lifecycle |
| Agent | ADAPT | FM, CoreAI, MLX | recovery, replay |
| Context | BUILD | contributor seam | blocks, budgets |
| Memory | ADAPT+BUILD | GRDB, Proxima opt | temporal, hybrid bar |
| Proxima | ADAPT | ProximaKit pinned | adoption gates |
| Search | BUILD+ADAPT | URLSession, WebKit, NL | extraction verdict |
| Sandbox | BUILD | WebKit, App Sandbox | threat-model proof |
| Connect | REUSE+ADAPT | MCP Swift SDK | lifecycle verdict |
| CompUse | BUILD | App Intents, A11y | semantic breadth |
| ModelsUI | BUILD | SwiftUI | state, labels |
| Full | REUSE | facade only | scope guard |

- KD3: no new third-party dependency in this plan. PENDING candidates (RecallKit sparse experiment, SwiftSoup/Readability extraction, AgentRunKit checkpoint semantics) enter only through a credential-free consumer probe plus a benchmark against the Archon-owned baseline, then a matrix/audit/backlog update (D-007; `context/native-candidate-audit.md:89-99`).
- KD4: sequencing follows the backlog Waves A to D and the scorecard next-evidence order: memory adapter evidence, agent recovery, search offline/citations, sandbox/computer-use threat model, MCP lifecycle, app validation (`Documentation/reference/competitor-comparison.md:517-526`).
- KD5: win definition per product is honest: beat rivals on on-device outcomes (privacy, latency, offline, cost, determinism), match table-stakes local quality bars, and keep physically hosted-scale capabilities as explicit, consented adapters rather than fake parity claims.

## Recommended Approach

Work gate-first, reuse-first, one landable unit at a time. Each unit below names its backlog IDs, the exact open gates it closes, the surfaces it touches, and its done criteria. Adapters stay optional and product-scoped; defaults change only when the scorecard rubric is fully true; every unit extends the owning product's deterministic edge-case suite and re-runs dependents (`ArchonFullTests`). Context files (`build-plan.md`, `progress-tracker.md`, plus the matrix/audit/log/scorecard the unit affects) update in the same change per `AGENTS.md`.

## Work Plan

### Wave A — Local intelligence foundation

- A1 Agent durability (AGENT-001, AGENT-002). Surfaces: `Sources/ArchonAgent` graph, `StateCheckpointer`, `GraphInterrupt`, idempotent tool-effect receipts. ADAPT durable-graph patterns; BUILD crash/reopen, deterministic replay/fork, stale-token, cancellation-race, and no-duplicate-side-effect behavior. Reference AgentRunKit checkpoint/stream semantics only through a credential-free probe first (`context/agent-candidate-comparison.md:31-32`). Done: scenario matrix in `context/quality-scorecard.md:112-121` covered by tests.
- A2 Memory semantics (MEMORY-001 to MEMORY-004). Surfaces: `Sources/ArchonMemory` extractor, validity/history fields, `GraphStore`, scopes, `VectorStore`/`VectorIndex`, export/forget paths. BUILD contradiction/temporal/supersession semantics, scope isolation, profile synthesis provenance; close the canonical Recall@10 workload at 0.99. Done: memory scenario matrix (`context/quality-scorecard.md:99-110`) green including reopen, migration, and CloudKit-conflict paths.
- A3 Memory index adoption gates (MEMORY-005). Surfaces: `Sources/ArchonMemoryProxima` adapter behind `VectorIndex`; optional RecallKit sparse experiment behind the same seam style. ADAPT pinned ProximaKit; prove persistence/recovery, memory ceilings, update/delete workloads, filtered search, and iOS-sized measurements per `context/memory-index-benchmark.md:73-79`. Done: rubric items 1 to 6 true for a default-change proposal, or adapter stays optional with gates documented.
- A4 Model routing and lifecycle (MODEL-001 to MODEL-003). Surfaces: `Sources/ArchonModels` catalogs, `ModelRuntimeAdapter`, lifecycle managers; `ArchonAgent` adaptive selection bridge. ADAPT MLX/HF/Foundation Models/Core AI runtimes; extend capability negotiation (streaming, vision, structured output, tools, context, locality) and device-tier routing tests. Done: mismatch, pressure, local-only routing, and explicit fallback cases in `context/quality-scorecard.md:112-121` covered; real-inference gates stay consuming-app items.
- A5 Context blocks and Core policy (CONTEXT-002, CORE-001, CORE-002). Surfaces: `Sources/ArchonContext` contributors/blocks, `Sources/ArchonCore` policy/redaction/device facts. BUILD working-memory blocks with limits, shared-scope isolation, consent, and provenance; per-target availability matrix for Apple APIs. Done: block-limit, redaction, no-persistence, cancellation, and `localOnly` network-denial tests green.

### Wave B — Search and connectivity

- B1 Extraction verdict (SEARCH-003). Run the pending SwiftSoup/Readability/WebKit-readability probes plus a corpus benchmark against the shipped dependency-free `HeuristicArticleExtractor` (`context/native-candidate-audit.md:74-87`, `context/build-plan.md:264-275`). ADAPT a winner only behind the `ArticleExtractor` seam with bounds, provenance, and license review; otherwise keep BUILD heuristic + WebKit escalation. Done: decision recorded in matrix/audit/log; corpus numbers in context.
- B2 Crawl, dedupe, and citation proof (SEARCH-001, SEARCH-002). Surfaces: `Sources/ArchonSearch` frontier, registry, reranker, citation graph. Harden robots/rate limits, budgets, deterministic dedupe, freshness metadata, and claim-to-source mapping; network-denied fixtures prove local-only purity. Done: search scenario checks (`context/quality-scorecard.md:123-131`) green.
- B3 MCP lifecycle verdict (CONNECT-001). Surfaces: `Sources/ArchonConnect` `OfficialMCPTransport`, policy/authorization boundary. Complete arbitrary-notification forwarding, authorizer injection, production-server socket teardown, and full conformance evidence (D-004). Done: explicit replace/wrap/retain decision recorded; no silent dual protocol engines.

### Wave C — Safety and action

- C1 Sandbox threat model (SANDBOX-001; SANDBOX-002 stays optional-remote). Surfaces: `Sources/ArchonSandbox` config, scheme handler, bridge, quotas, cleanup, audit. Prove traversal, CSP, blocked-network, quota, bridge-abuse, cleanup, and isolation-label behavior; local WebKit stays labelled in-process WebKit. Done: sandbox scenario checks (`context/quality-scorecard.md:123-131`) green.
- C2 Computer-use semantic breadth (COMPUTER-001 to COMPUTER-003). Surfaces: `Sources/ArchonComputerUse` observations, risk policy, approvals, postconditions, fallback. REUSE App Intents, Accessibility, DOM semantics as host sources; BUILD stale-state, risk-gate, pause/resume, and audit behavior; bound the screenshot/coordinate fallback with permission and visible uncertainty. Done: computer-use scenario checks (`context/quality-scorecard.md:123-131`) green at package level; live interaction stays a consuming-app gate.

### Wave D — UI, facade, and release handoff

- D1 Model UI and facade (UI-001, FULL-001). Surfaces: `Sources/ArchonModelsUI`, `Sources/ArchonFull`. State-driven browser/library/detail/storage surfaces over injected `ArchonModels` state, accessibility identifiers, no duplicate store; facade stays a re-export with the scope checker green. Done: `ArchonModelsUITests` + `ArchonFullTests` green; simulator compilation for iOS and visionOS.
- D2 Release and handoff checklist. Re-run all checkers, refresh the license inventory snapshot, re-score affected scorecard rows with the validator, and write the consuming-app handoff: signed-app flows, App Intents, accessibility review, representative iPhone/iPad/Mac/visionOS device matrix, and DNS-binding ownership. Done: release gates in `context/dependency-license-inventory.md:45-54` and `context/build-plan.md:298-309` either evidenced or explicitly carried as consuming-app items.

Each unit is independently landable in wave order; A1/A2/A4/A5 can parallelize, A3 follows A2, Wave B follows Wave A, C1/C2 parallelize after B2, D1/D2 close the release.

## Validation Plan

- Per unit: focused `swift test --filter <Bundle>Tests` for the touched product plus `ArchonFullTests` when its surface is affected; `swift build` for affected products; `git diff --check`. Extend the owning `*EdgeCasesTests`/`*CoverageTests` suite for every behavior, error, or boundary change (per-product rule in `AGENTS.md`).
- Known environment carve-out: run the Connect bundle with `--skip LoopbackMCPServerTests` until the pre-existing environmental hang is resolved; record the skip in the unit's progress entry (`context/progress-tracker.md:1406-1412`).
- Per wave: `swift build -j 2`; `swift Tools/verify-product-scope.swift`; `swift Tools/verify-dependency-licenses.swift`; `swift Tools/verify-competitor-scorecard.swift`; simulator compilation for touched products (iOS and visionOS for UI/facade units).
- Release: full `swift test -j 2 --skip LoopbackMCPServerTests`, all three checkers, and the scorecard validator must pass; device, signed-app, live-UI, and real-model gates are validated only in a consuming app with fresh evidence, never claimed from mocks (D-008).
- Highest-risk validation step: the memory replacement rubric (Recall@10, p95, ceilings, recovery, migration) and the MCP replace/wrap/retain conformance call, because both decide defaults other products inherit.

## Risks / Rollback

- Scope creep into hosted parity: guarded by KD5 and D-013; any unit that drifts toward re-implementing hosted scale gets rescoped to an explicit adapter or INSPIRATION.
- Proxima default risk: the rubric is all-or-nothing; partial evidence keeps the adapter optional, so rollback is simply not changing the default (`context/quality-scorecard.md:140-158`).
- MCP dual-engine risk: the custom transport stays the default until the B3 verdict; no silent protocol split (D-004).
- Dependency risk: KD3 forbids new third-party packages without probe plus benchmark; every unit re-runs the license and scope checkers, so an accidental graph change fails fast.
- Device-gate risk: package evidence cannot prove device behavior; Wave D converts every unprovable claim into a named consuming-app checklist item instead of a mock-based acceptance.
- Rollback per unit is a clean revert: units are additive behind existing seams (`VectorIndex`, `ArticleExtractor`, `SearchProvider`, `SandboxExecutionProvider`, transport selection) with no cross-unit schema coupling except A2 to A3, which ships together if migration formats change.

## Open Questions

1. Live-web strictness: is explicit, user-consented client fetching of public web pages acceptable (recommended default in KD1), or must live search also be strictly offline? If strictly offline, the SEARCH-003 network path and any future cloud search adapters drop to P3/out of scope and B1/B2 shrink to local-corpus-only.
2. Consuming-app and device access: what signed app, Apple hardware, and timeline are available for the Wave D device matrix? This sets whether D2 items get fresh evidence or stay carried as explicit acceptance gates.
