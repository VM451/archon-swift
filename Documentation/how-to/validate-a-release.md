# Validate a release

Use a layered evidence plan. Passing package tests is necessary but does not
prove a signed app or physical-device integration.

## Package checks

From the repository root:

```bash
swift package dump-package
swift build -j 2
swift test -j 2
swift Tools/verify-product-scope.swift
swift Tools/verify-dependency-licenses.swift
git diff --check
```

Run timing-sensitive checks separately with the opt-in command in
[`Benchmarks/README.md`](../../Benchmarks/README.md).

## Product acceptance

For each changed capability, include focused tests for:

- cancellation, bounded resources, and typed failure behavior;
- permission denial and local-only network rejection;
- persistence, reopen, deletion, migration, and crash recovery where state is
  durable;
- security boundaries, path handling, credential redaction, and audit events;
- compatibility across the claimed Apple platforms; and
- performance on representative device tiers.

## Consuming-app checks

In a signed Xcode app, validate entitlements, privacy usage descriptions,
App Intents, lifecycle delivery, accessibility, live UI, model loading with a
real artifact, and physical-device behavior. Record blocked or untested gates
explicitly; do not substitute simulator or package evidence for them.

## Replacement gate

An alternative implementation cannot become the default until it meets the
[quality scorecard](../../context/quality-scorecard.md), including recall,
p95 latency, memory budget, persistence/recovery, migration, privacy, and
consuming-app evidence.
