# ``ArchonMemory``

A native Swift, local-first AI memory framework uniting the innovations of Mem0, Supermemory, Letta/MemGPT, and Zep for Apple Silicon, with optional Apple CloudKit synchronization.

## Overview

ArchonMemory provides persistent long-term memory for Apple Intelligence agentic systems, virtual assistants, and conversational native applications running on **iOS 27.0+ and macOS 27.0+**.

It automatically extracts structured user facts, preferences, and entity-relationship knowledge graphs using Apple Foundation Models, indexes float array vectors locally using Apple's `Accelerate.framework` (SIMD/vDSP) and SQLite FTS5, ingests documents and bookmarks (Supermemory), provides 3-tier memory management (Letta/MemGPT), dialogue summarization (Zep), and can synchronize memory state privately across user devices using an explicitly configured CloudKit container.

## Topics

### Essentials
- <doc:GettingStarted>
- <doc:AppleFoundationModels>
- <doc:GraphMemoryGuide>
- <doc:CompetitorComparison>
- <doc:CloudKitSyncGuide>
- <doc:CustomLLMProvider>

### Client & Configuration
- ``ArchonClient``
- ``ArchonConfig``

### Core Data Models & Graphs
- ``MemoryItem``
- ``Entity``
- ``Relation``
- ``GraphTriple``
- ``DocumentItem``
- ``RecallMessage``
- ``ConversationSummary``
- ``MemoryTier``
- ``Message``
- ``MemoryFilter``
- ``SearchResult``
- ``MemoryHistoryItem``
- ``CoreMemoryBlock``

### Core Storage & Search
- ``VectorStore``
- ``GraphStore``
- ``LocalVectorStore``
- ``LocalGraphStore``
- ``VectorMath``

### Intelligence & Reasoning
- ``EmbeddingProvider``
- ``LLMProvider``
- ``MemoryExtractor``
- ``ContentChunker``
- ``DialogueSummarizer``
- ``AppleFoundationModelProvider``
- ``OllamaProvider``
- ``OpenAIProvider``

### CloudKit Synchronization
- ``CloudKitSyncEngine``

### Platform Integrations
- ``CoreSpotlightIndexer``
- ``SearchMemoriesIntent``
- ``AddMemoryIntent``
- ``ArchonBackgroundTaskHandler``
