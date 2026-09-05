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
