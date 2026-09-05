# CloudKit Synchronization Guide

Configure multi-device private iCloud synchronization without third-party vector databases.

## Overview

`ArchonMemory` optionally uses an explicitly configured CloudKit private database inside a custom record zone (`ArchonPrivateZone`). Local storage remains authoritative and CloudKit is disabled by default.

### Privacy First

- Memories stay strictly inside the end user's personal iCloud container.
- Developers and third parties cannot access stored user memories.
- Transmitted data is protected with TLS and encrypted at rest on Apple servers.

### Conflict Resolution Strategy

When changes occur concurrently across an iPhone and Mac:
1. **Higher Scalar Version Wins**: Items with a higher scalar `version` take precedence.
2. **Last-Write-Wins (LWW)**: Equal versions fall back to comparing modification timestamps (`updatedAt`).

### Enabling CloudKit Sync

Enable iCloud CloudKit entitlement in your Xcode App Target settings under **Signing & Capabilities** -> **iCloud** -> **CloudKit**.

Pass the exact container identifier from the consuming app. Omitting it while
enabling sync fails closed:

```swift
let archon = try await ArchonClient(config: ArchonConfig(
    cloudKitContainerId: "iCloud.com.example.myapp",
    enableAutoSync: true
))
```

The client uploads pending local records, applies remote deltas, and commits a
per-container change token only after local application. Call `sync()` when the
host receives a background refresh or CloudKit push opportunity.
