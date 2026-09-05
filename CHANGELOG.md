# Changelog

## Unreleased

### Added

- Shared HTTPS and resolved-address network policy with fail-closed defaults.
- CI checks for package builds, Swift Testing, product scope, dependency-license
  evidence, scorecard structure, and whitespace.
- Resource and request-size limits for model catalogs, agent tools, providers,
  and local vector memory.

### Changed

- Graph builders are single-owner, require an explicit entry point, validate
  references before compilation, and install reducers synchronously.
- Tool effect ledgers reserve call IDs atomically and replay completed effects
  safely under retries.
- Cloud provider capabilities now report non-streaming behavior until native
  incremental transport is implemented; provider credentials are no longer
  publicly readable.
- Model replacement restores the previous resident set on a failed load, and
  background model installs use atomic replacement.

### Migration notes

- `GraphBuilder.compile()` is now throwing. Handle `GraphError.invalidGraph` and
  provide an explicit `setEntryPoint(...)`.
- Custom `ToolEffectLedger` implementations must adopt
  `reserve(callID:toolName:)`, `record(_:)`, and `release(callID:)`.

The MLX Swift, MLX LM, Hugging Face, and Transformers dependencies intentionally
remain in `ArchonAgent` so local-agent functionality is ready out of the box.
