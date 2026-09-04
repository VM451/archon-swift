# ArchonCore

`ArchonCore` is the lightweight shared foundation. It defines values and
policies used by other products without owning their storage, inference,
transport, or UI implementation.

## Main contracts

- `ArchonPermission` describes capabilities such as network, storage,
  clipboard, camera, microphone, location, and external URLs.
- `ArchonCapability` and platform/version values describe availability without
  inventing support.
- `ArchonDeviceCapabilities.current` reports device, OS, memory, architecture,
  thermal, and Apple runtime availability facts.
- `ArchonLogger` provides an injectable logging boundary; the default logger is
  a no-op.
- Shared model runtime/task/capability values are used by model and agent
  routing.

Keep host authorization and user-facing permission prompts in the consuming
application. `ArchonCore` describes policy; it does not grant Apple's system
permissions.
