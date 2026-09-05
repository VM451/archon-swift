import Foundation

/// Portable JSON snapshot of durable ArchonMemory state.
public struct ArchonMemoryExport: Codable, Equatable, Sendable {
    public let memories: [MemoryItem]
    public let history: [MemoryHistoryItem]
    public let entities: [Entity]
    public let relations: [GraphTriple]

    public init(
        memories: [MemoryItem],
        history: [MemoryHistoryItem],
        entities: [Entity],
        relations: [GraphTriple]
    ) {
        self.memories = memories
        self.history = history
        self.entities = entities
        self.relations = relations
    }
}
