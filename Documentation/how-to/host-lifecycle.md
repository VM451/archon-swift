# Host lifecycle, permissions, and App Intents

Archon is a package, not an application delegate. The consuming app must
forward platform lifecycle events and register host-owned services.

## Register the model library

Register the same actor used by model UI and App Intents:

```swift
import ArchonModels

let library = ModelLibrary.makeDefault()
await ModelLibraryIntentRegistry.shared.register(library)
```

This avoids a second model store. Intents fail closed when no library is
registered.

## Forward model lifecycle

When the app enters background, receives memory pressure, or changes thermal
state, call the corresponding `ModelLoadManager` hook. Use the same manager
that owns the loaded runtime. Select an explicit unload policy on background
rather than assuming the operating system will preserve a resident model.

## Supply permissions at the right layer

The app owns entitlements, privacy usage descriptions, authorization prompts,
and host objects. `ArchonPermission`, search policy, MCP risk policy, and
Computer Use risk policy describe what the SDK may do after the host grants
authority; they do not replace Apple's permission systems.

## Validate in the real host

Package tests can verify actor behavior and typed failures. Only a consuming
Xcode application can verify App Intents registration, lifecycle delivery,
background URLSession relaunch, signed entitlements, and physical-device
resource pressure.
