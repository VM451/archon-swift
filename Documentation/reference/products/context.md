# ArchonContext

`ArchonContext` assembles the current request context from registered
`ContextContributor` values. It is ephemeral infrastructure between durable
memory/search/tool data and a model request.

## Deterministic behavior

- Contributors are identified and ordered deterministically.
- Fragments are ordered by descending priority, then stable identity.
- `ContextBudget` can cap UTF-8 bytes and fragment count.
- Only the final included fragment is truncated when a byte budget is reached.
- Cancellation is checked between contributor calls.

`ContextBuilder` does not persist, retrieve, mutate memory, execute tools, or
decide whether content is trustworthy. Durable facts remain in
`ArchonMemory`; the host decides which contributors are appropriate for a
request.
