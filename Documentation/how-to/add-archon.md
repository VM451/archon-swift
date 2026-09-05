# Add Archon to an application

## 1. Add the package

In Xcode, add:

```text
https://github.com/VM451/archon-swift.git
```

For development, track `main`. For a production application, pin a release
tag or commit so dependency resolution is reproducible.

## 2. Choose products deliberately

Import the smallest product set that owns the capability. Use
[the product reference](../reference/products.md) for the complete map.

```swift
import ArchonCore
import ArchonModels
import ArchonAgent
```

Use `ArchonFull` only when the convenience facade is worth importing the full
base graph. It does not include `ArchonMemoryProxima`.

## 3. Configure the host boundary

The application, not the package, provides:

- API keys and secure credential storage;
- entitlements and privacy usage descriptions;
- App Intents registration and lifecycle forwarding;
- model-family tokenizers and text-generation adapters;
- MCP servers, search providers, and remote sandbox adapters; and
- semantic observations, user approvals, and side-effect policy.

For model discovery, inject the catalog that the application intends users to
browse. The model UI is data-driven; the bundled Gemma adaptive seed is not a
complete discovery registry. See [Supported models and model-family policy](../reference/supported-models.md).

## 4. Select a policy

Choose local-only, local-preferred, Apple-only, or cloud-allowed behavior
explicitly. Do not hide a fallback in a convenience initializer. See
[local-first boundaries](../explanation/local-first-boundaries.md).

## 5. Verify the integration

Run package checks, then validate in a consuming Xcode application on every
target platform you claim to support. Package compilation cannot prove signed
app entitlements, live UI behavior, physical-device performance, or a model's
real tokenizer/function contract.
