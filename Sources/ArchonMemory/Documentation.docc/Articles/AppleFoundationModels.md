# Apple Foundation Models & Agentic Systems Integration

Learn how ArchonMemory is purpose-built to provide native persistent memory exclusively for Apple Intelligence, Apple Foundation Models, and CloudKit.

## Overview

ArchonMemory is designed specifically for Apple native applications. Rather than requiring heavy Python servers or external vector databases (Qdrant, Pinecone, Postgres), ArchonMemory pairs directly with **Apple Foundation Models** and **Apple CloudKit**.

### Key Integration Highlights

- **On-Device Foundation Models & Guided Generation**: Utilizes Apple Silicon hardware acceleration (`Accelerate.framework` SIMD / vDSP) for vector operations and JSON guided generation schema parsing.
- **Zero Third-Party Backend**: Syncs memory items across the user's iOS 27+ and macOS 27+ devices using `CKContainer.default().privateCloudDatabase`.
- **System Native Integration**: Integrates directly into Apple system search (`CSSearchableIndex`), Siri/Shortcuts (`AppIntents`), and background consolidation (`BGTaskScheduler`).

```swift
import ArchonMemory

// Zero-configuration: defaults to Apple Foundation Models + CloudKit
let archon = try await ArchonClient(config: ArchonConfig())

// Store conversational facts extracted via Apple Foundation Model
try await archon.add(memory: "User prefers dark mode UI and resides in Bangkok", userId: "user_bkk")

// Search relevant memory context for Apple Intelligence prompt construction
let results = try await archon.search(query: "User preferences", userId: "user_bkk")
```
