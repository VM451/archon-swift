# ArchonContext

`ArchonContext` assembles the current request context from registered
`ContextContributor` values. It is ephemeral infrastructure between durable
memory/search/tool data and a model request.

## Deterministic behavior

- Contributors are identified and ordered deterministically.
- Contributor work is evaluated concurrently with structured task groups, then
  normalized into deterministic order before the snapshot is returned.
- Fragments are ordered by descending priority, then stable identity.
- `ContextBudget` can cap UTF-8 bytes and fragment count.
- `ContextBudget` can also cap estimated tokens through an injected
  `ContextTokenEstimator`; the built-in estimator is deterministic and
  dependency-free.
- Fragments preserve provenance and trust metadata, and truncation is marked in
  the returned fragment metadata for observability.
- Only the final included fragment is truncated when a byte budget is reached.
- Cancellation is checked before and during contributor evaluation and after the
  task group completes.

`ContextBuilder` does not persist, retrieve, mutate memory, execute tools, or
decide whether content is trustworthy. Durable facts remain in
`ArchonMemory`; the host decides which contributors are appropriate for a
request.

## Token profiles

`FamilyAwareTokenEstimator` applies a per-model-family bytes-per-token
divisor (`ModelFamilyTokenProfile`: Apple Foundation, Gemma, Llama, Mistral,
Claude, GPT, plus a UTF-8 fallback) with an optional explicit override.
The fallback divisor matches `UTF8ContextTokenEstimator` exactly, and all
estimates are deterministic and clamped at zero.

## Summarization seam

`ContextSummarizer` is a host-supplied, on-device summarizer boundary.
`ContextBuilder.summarizedSnapshot(budget:summarizer:fallbackToTruncation:latencyPolicy:)`
passes ordered fragments to the summarizer and re-applies deterministic
ordering; summarized fragments keep their own provenance and trust. A `nil`
or throwing summarizer falls back to deterministic truncation when
`fallbackToTruncation` is set, otherwise the error propagates. Cancellation
is honored before and after summarization.

## Contributor latency budgets

`ContributorLatencyPolicy` sets a per-contributor timeout (non-positive
values are rejected). Timeouts fail closed with typed
`ContributorLatencyError.contributorTimeout`; skip-mode is explicitly
deferred so partial context is never silently returned. Generous budgets
preserve deterministic priority/identity ordering.
