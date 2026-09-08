import Foundation

/// Portable JSON snapshot of durable ArchonMemory state.
public struct ArchonMemoryExport: Codable, Equatable, Sendable {
    public let memories: [MemoryItem]
    public let history: [MemoryHistoryItem]
    public let entities: [Entity]
    public let relations: [GraphTriple]
    public let documents: [DocumentItem]
    public let feedback: [MemoryFeedbackEvent]
    public let competitiveResearchSnapshots: [CompetitiveResearchSnapshot]

    public init(
        memories: [MemoryItem],
        history: [MemoryHistoryItem],
        entities: [Entity],
        relations: [GraphTriple],
        documents: [DocumentItem] = [],
        feedback: [MemoryFeedbackEvent] = [],
        competitiveResearchSnapshots: [CompetitiveResearchSnapshot] = []
    ) {
        self.memories = memories
        self.history = history
        self.entities = entities
        self.relations = relations
        self.documents = documents
        self.feedback = feedback
        self.competitiveResearchSnapshots = competitiveResearchSnapshots
    }

    private enum CodingKeys: String, CodingKey {
        case memories, history, entities, relations, documents, feedback, competitiveResearchSnapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.memories = try container.decode([MemoryItem].self, forKey: .memories)
        self.history = try container.decode([MemoryHistoryItem].self, forKey: .history)
        self.entities = try container.decode([Entity].self, forKey: .entities)
        self.relations = try container.decode([GraphTriple].self, forKey: .relations)
        self.documents = try container.decodeIfPresent([DocumentItem].self, forKey: .documents) ?? []
        self.feedback = try container.decodeIfPresent([MemoryFeedbackEvent].self, forKey: .feedback) ?? []
        self.competitiveResearchSnapshots = try container.decodeIfPresent([CompetitiveResearchSnapshot].self, forKey: .competitiveResearchSnapshots) ?? []
    }
}
