# Model documentation

This compatibility page remains at the original path for existing links. The
model contract is now split by concern:

- [Model contract](reference/model-contract.md) — manifest, format/runtime
  compatibility, resource rules, and installation state machine.
- [Model catalogs](reference/model-catalogs.md) — local, static, direct URL,
  Apple, Archon, Hugging Face, remote, and composite discovery.
- [Supported models](reference/supported-models.md) — MLX-only user-facing
  discovery, model-family coverage within MLX, catalog wiring, and the Gemma
  compatibility convenience.
- [Model lifecycle](reference/model-lifecycle.md) — library, downloads,
  background transfers, runtime loading, and failure posture.
- [Executable reference](reference/executables.md) — `archon-model` commands
  and the example executable.
- [First local model tutorial](tutorials/first-local-model.md) — a safe,
  offline discovery and import path.

An `archon-model.json` manifest is the source of truth for an installed
artifact's declared runtime, resources, integrity, license, platform support,
and capabilities. A model name or filename is never sufficient to claim that
an artifact is runnable.
