# Getting Started with ArchonMemory

Integrate persistent AI user memory into your Apple Intelligence app in 5 minutes.

## Overview

ArchonMemory is purpose-built for Apple Foundation Models and optional CloudKit. It extracts, stores, retrieves, and deduplicates conversational context locally by default.

### 1. Add SPM Dependency

Add `ArchonMemory` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VM451/archon-memory-swift.git", from: "1.0.0")
]
```

### 2. Zero-Configuration Initialization

By default, `ArchonConfig` uses Apple Foundation Models for structured memory extraction and keeps persistence local. Enable private multi-device sync only after configuring the consuming app's CloudKit entitlement and container:

```swift
import ArchonMemory

let archon = try await ArchonClient(config: ArchonConfig())

let syncedArchon = try await ArchonClient(config: ArchonConfig(
    cloudKitContainerId: "iCloud.com.example.myapp",
    enableAutoSync: true
))
```

### 3. Extract Facts from Conversation Turns

```swift
let messages = [
    Message(role: .user, content: "Hi, I live in Bangkok and prefer dark mode."),
    Message(role: .assistant, content: "Got it! I will remember that you live in Bangkok and prefer dark mode.")
]

let result = try await archon.add(
    messages: messages,
    userId: "user_123"
)

print("Extracted Memories:", result.affectedItems.map { $0.memory })
```

### 4. Search Relevant Context for Prompt Construction

```swift
let searchResults = try await archon.search(
    query: "Where does the user live?",
    userId: "user_123",
    limit: 3
)

for item in searchResults {
    print("Found Memory:", item.item.memory, "(Score:", item.score, ")")
}
```

### 5. Migrate a Derived Vector Index from the Durable Store

Derived indexes (such as the optional Proxima adapter) always rebuild from
durable truth. Migrate, verify recall, and roll back by keeping the old index
serving — migration never mutates the durable store:

```swift
import ArchonMemory
import ArchonMemoryProxima

// 1. Rebuild the new index from the durable store under a fail-closed ceiling.
let report = try await proximaIndex.migrate(
    from: localStore,
    ceiling: ProximaResourceCeiling(maxRecords: 20_000, maxSnapshotBytes: 16_777_216)
)
print("Migrated \(report.indexed) records, skipped \(report.skipped), snapshot \(report.bytes) bytes")

// 2. Verify recall against brute-force truth before switching traffic.
// 3. Rollback: a failed or cancelled migration leaves the old index serving,
//    so rollback is simply "keep serving the old index".

// Recover from a lost or corrupt snapshot the same way:
let rebuilt = try await proximaIndex.restoreOrRebuild(snapshot: snapshotURL, fallback: localStore)
print(rebuilt ? "Rebuilt from durable store" : "Restored snapshot")
```
