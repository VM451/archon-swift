# Archon Example App

Buildable SwiftPM host for validating package composition on macOS, iOS, and
visionOS 27.

## Run

```bash
swift run archon-example-app
```

## Covers

- installed-model library and storage views;
- Files import and macOS drag-and-drop of compatible model artifacts;
- Hugging Face discovery, filters, compatibility, and revision checks;
- real download lifecycle: pause, resume, retry, redownload, delete, and select;
- model-library App Intents, discoverable App Shortcuts, and installed-model entity registration;
- Apple Foundation Model chat when the host device supports it.

## Boundary

This is a SwiftPM example host, not a signed `.app`. The consuming application
still owns credentials, entitlements, privacy usage descriptions, permissions,
and custom model text-generation adapters.

See the [root README](../README.md) for the system design and package map.
