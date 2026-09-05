# Knowledge Graph Memory Guide

Extract, store, and query relational entity graphs locally on Apple Silicon.

## Overview

ArchonMemory includes a local Knowledge Graph memory engine inspired by graphiti and Mem0. It extracts relational triples `(Subject, Relation, Object)` from conversation turns to maintain structured relationships alongside dense vector embeddings.

### Triples & Graph Architecture

- **`Entity`**: A discrete named node representing a person, location, preference, skill, or concept.
- **`Relation`**: A directed edge connecting two entities with relationship types (`lives_in`, `allergic_to`, `works_on`, `prefers`).
- **`GraphTriple`**: A flattened triple `(sourceEntityName, relationshipType, targetEntityName)` easily convertible into natural language prompt context.

### Accessing Knowledge Graph Memories

```swift
import ArchonMemory

let archon = try await ArchonClient(config: ArchonConfig())

// 1. Extract entities and relations from conversation
let messages = [
    Message(role: .user, content: "Hi, I am Alex and I live in Bangkok.")
]
try await archon.add(messages: messages, userId: "alex_123")

// 2. Query all extracted graph triples
let triples = try await archon.getRelations(userId: "alex_123")
for triple in triples {
    print("\(triple.sourceEntityName) -> [\(triple.relationshipType)] -> \(triple.targetEntityName)")
}
// Prints: Alex -> [lives_in] -> Bangkok
```

### CloudKit Multi-Device Graph Sync

When CloudKit is enabled, knowledge graph entities and relations are serialized into `ArchonEntity` and `ArchonRelation` `CKRecord` types and synchronized across the user's Apple devices using private database subscriptions.
