# Security policy

Archon is a local-first SDK. Security-sensitive changes include credential
handling, model artifact validation, network destination policy, tool effects,
filesystem boundaries, sandbox capabilities, persistence, and privacy behavior.

## Reporting a vulnerability

Please do not publish exploit details in a public issue. Use a private GitHub
security advisory for this repository when available. If private advisories are
not enabled, contact the repository maintainers through a private channel and
include the affected product, revision, impact, reproduction steps, and any
safe mitigation.

## Disclosure expectations

Reports are triaged against the latest revision first. Do not include API keys,
model credentials, personal data, or private model artifacts in a report.
Maintainers should confirm the report, scope the impact, add regression coverage,
and document any release or migration requirement before public disclosure.
