import Foundation
import CommonCrypto

enum CompetitiveResearchIdentity {
    static func stableUUID(_ key: String) -> UUID {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(key.utf8)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// The role an insight plays in a competitive research record.
public enum CompetitiveInsightKind: String, Codable, Sendable, Hashable {
    case switchTrigger
    case stayReason
    case capability
    case risk
}

/// Confidence assigned to a research claim. Directional claims are useful for
/// prioritization but must not be presented as verified customer evidence.
public enum CompetitiveInsightConfidence: Int, Codable, Sendable, Hashable, Comparable {
    case unverified = 0
    case directional = 1
    case supported = 2
    case high = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A source captured by a consumer-owned research importer.
public struct CompetitiveSource: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let url: String
    public let publisher: String?
    public let retrievedAt: Date
    public let publishedAt: Date?
    public let license: String?

    public init(
        id: String? = nil,
        title: String,
        url: String,
        publisher: String? = nil,
        retrievedAt: Date = Date(),
        publishedAt: Date? = nil,
        license: String? = nil
    ) {
        self.id = id ?? url
        self.title = title
        self.url = url
        self.publisher = publisher
        self.retrievedAt = retrievedAt
        self.publishedAt = publishedAt
        self.license = license
    }
}

/// A source-backed claim about a provider, platform, or implementation.
public struct CompetitiveInsight: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let providerID: String
    public let providerName: String
    public let kind: CompetitiveInsightKind
    public let claim: String
    public let sourceIDs: [String]
    public let sourceURLs: [String]
    public let confidence: CompetitiveInsightConfidence
    public let validFrom: Date
    public let validTo: Date?
    public let supersedesID: UUID?
    public let tags: [String]

    public init(
        id: UUID = UUID(),
        providerID: String,
        providerName: String,
        kind: CompetitiveInsightKind,
        claim: String,
        sourceIDs: [String],
        sourceURLs: [String] = [],
        confidence: CompetitiveInsightConfidence = .directional,
        validFrom: Date = Date(),
        validTo: Date? = nil,
        supersedesID: UUID? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.kind = kind
        self.claim = claim
        self.sourceIDs = sourceIDs
        self.sourceURLs = sourceURLs
        self.confidence = confidence
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersedesID = supersedesID
        self.tags = tags
    }

    public var searchableText: String {
        "\(providerName) \(kind.rawValue) \(claim)"
    }
}

/// Aggregated provider positioning kept alongside the individual claims.
public struct ProviderProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: String { providerID }
    public let providerID: String
    public let providerName: String
    public let deploymentModel: String
    public let license: String?
    public let switchTriggers: [String]
    public let stayReasons: [String]
    public let knownLimitations: [String]
    public let updatedAt: Date

    public init(
        providerID: String,
        providerName: String,
        deploymentModel: String,
        license: String? = nil,
        switchTriggers: [String] = [],
        stayReasons: [String] = [],
        knownLimitations: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.deploymentModel = deploymentModel
        self.license = license
        self.switchTriggers = switchTriggers
        self.stayReasons = stayReasons
        self.knownLimitations = knownLimitations
        self.updatedAt = updatedAt
    }

    public var searchableText: String {
        ([providerName, deploymentModel] + switchTriggers + stayReasons + knownLimitations).joined(separator: "\n")
    }
}

/// An idempotent, versioned import unit produced outside the package.
public struct CompetitiveResearchSnapshot: Identifiable, Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let providerID: String
    public let providerName: String
    public let userId: String?
    public let retrievedAt: Date
    public let sources: [CompetitiveSource]
    public let profile: ProviderProfile?
    public let insights: [CompetitiveInsight]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        providerID: String,
        providerName: String,
        userId: String? = nil,
        retrievedAt: Date = Date(),
        sources: [CompetitiveSource],
        profile: ProviderProfile? = nil,
        insights: [CompetitiveInsight]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerName = providerName
        self.userId = userId
        self.retrievedAt = retrievedAt
        self.sources = sources
        self.profile = profile
        self.insights = insights
    }

    public var searchableText: String {
        let sourceText = sources.map { source in
            [source.title, source.publisher, source.url].compactMap { $0 }.joined(separator: " ")
        }
        let profileText = profile.map { [$0.searchableText] } ?? []
        return ([providerName] + sourceText + profileText + insights.map(\.searchableText)).joined(separator: "\n")
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ArchonMemoryError.invalidCompetitiveResearch("Unsupported research schema version \(schemaVersion).")
        }
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchonMemoryError.invalidCompetitiveResearch("Provider identity is required.")
        }
        guard !sources.isEmpty else {
            throw ArchonMemoryError.invalidCompetitiveResearch("At least one source is required.")
        }

        let sourceIDs = Set(sources.map(\.id))
        for source in sources {
            guard let url = URL(string: source.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw ArchonMemoryError.invalidCompetitiveResearch("Source URLs must be absolute HTTP(S) URLs.")
            }
        }

        for insight in insights {
            guard insight.providerID == providerID,
                  insight.providerName == providerName,
                  !insight.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchonMemoryError.invalidCompetitiveResearch("Every insight must match the snapshot provider and contain a claim.")
            }
            guard !insight.sourceIDs.isEmpty,
                  insight.sourceIDs.allSatisfy(sourceIDs.contains) else {
                throw ArchonMemoryError.invalidCompetitiveResearch("Every insight must reference a source in the snapshot.")
            }
            guard !insight.sourceURLs.isEmpty,
                  insight.sourceURLs.allSatisfy({ url in
                      sources.contains { $0.url == url }
                  }) else {
                throw ArchonMemoryError.invalidCompetitiveResearch("Every insight must retain at least one source URL from the snapshot.")
            }
            if let validTo = insight.validTo, validTo <= insight.validFrom {
                throw ArchonMemoryError.invalidCompetitiveResearch("Insight validity must have a positive time range.")
            }
        }

        if let profile, profile.providerID != providerID || profile.providerName != providerName {
            throw ArchonMemoryError.invalidCompetitiveResearch("The profile must match the snapshot provider.")
        }
    }
}

/// Structured filters for competitive insight recall.
public struct CompetitiveInsightFilter: Codable, Sendable, Hashable {
    public let providerID: String?
    public let sourceID: String?
    public let kinds: Set<CompetitiveInsightKind>
    public let minimumConfidence: CompetitiveInsightConfidence?
    public let asOf: Date?
    public let userId: String?

    public init(
        providerID: String? = nil,
        sourceID: String? = nil,
        kinds: Set<CompetitiveInsightKind> = [],
        minimumConfidence: CompetitiveInsightConfidence? = nil,
        asOf: Date? = nil,
        userId: String? = nil
    ) {
        self.providerID = providerID
        self.sourceID = sourceID
        self.kinds = kinds
        self.minimumConfidence = minimumConfidence
        self.asOf = asOf
        self.userId = userId
    }
}

/// A typed insight together with the retrieval score used to rank it.
public struct CompetitiveInsightMatch: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID { insight.id }
    public let insight: CompetitiveInsight
    public let score: Double

    public init(insight: CompetitiveInsight, score: Double) {
        self.insight = insight
        self.score = score
    }
}

/// Explicit local feedback used to learn whether recalled content was useful.
public enum MemoryFeedbackKind: String, Codable, Sendable, Hashable {
    case accepted
    case rejected
    case edited
    case forgotten
    case recalled
}

public struct MemoryFeedbackEvent: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let insightID: UUID
    public let kind: MemoryFeedbackKind
    public let userId: String?
    public let timestamp: Date
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        insightID: UUID,
        kind: MemoryFeedbackKind,
        userId: String? = nil,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.insightID = insightID
        self.kind = kind
        self.userId = userId
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public struct CompetitiveResearchIngestionReport: Codable, Sendable, Hashable {
    public let snapshotID: UUID
    public let providerID: String
    public let insightCount: Int
    public let profileStored: Bool

    public init(snapshotID: UUID, providerID: String, insightCount: Int, profileStored: Bool) {
        self.snapshotID = snapshotID
        self.providerID = providerID
        self.insightCount = insightCount
        self.profileStored = profileStored
    }
}

/// A deterministic, source-linked baseline for the first competitor research import.
public enum CompetitiveResearchSeed {
    private static let baselineDate = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!

    public static func initialSnapshots() -> [CompetitiveResearchSnapshot] {
        definitions.map { definition in
            let source = CompetitiveSource(
                title: definition.sourceTitle,
                url: definition.sourceURL,
                publisher: definition.publisher,
                retrievedAt: baselineDate,
                license: definition.license
            )
            let profile = ProviderProfile(
                providerID: definition.id,
                providerName: definition.name,
                deploymentModel: definition.deployment,
                license: definition.license,
                switchTriggers: [definition.switchReason],
                stayReasons: [definition.stayReason],
                knownLimitations: [definition.limitation],
                updatedAt: baselineDate
            )
            let switchInsight = CompetitiveInsight(
                id: CompetitiveResearchIdentity.stableUUID("\(definition.id):switch"),
                providerID: definition.id,
                providerName: definition.name,
                kind: .switchTrigger,
                claim: definition.switchReason,
                sourceIDs: [source.id],
                sourceURLs: [source.url],
                confidence: .directional,
                validFrom: baselineDate,
                tags: ["competitive-research", "switch-trigger"]
            )
            let stayInsight = CompetitiveInsight(
                id: CompetitiveResearchIdentity.stableUUID("\(definition.id):stay"),
                providerID: definition.id,
                providerName: definition.name,
                kind: .stayReason,
                claim: definition.stayReason,
                sourceIDs: [source.id],
                sourceURLs: [source.url],
                confidence: .supported,
                validFrom: baselineDate,
                tags: ["competitive-research", "stay-reason"]
            )
            return CompetitiveResearchSnapshot(
                id: CompetitiveResearchIdentity.stableUUID("\(definition.id):snapshot"),
                providerID: definition.id,
                providerName: definition.name,
                retrievedAt: baselineDate,
                sources: [source],
                profile: profile,
                insights: [switchInsight, stayInsight]
            )
        }
    }

    private struct Definition {
        let id: String
        let name: String
        let sourceTitle: String
        let sourceURL: String
        let publisher: String
        let license: String?
        let deployment: String
        let switchReason: String
        let stayReason: String
        let limitation: String
    }

    private static let definitions: [Definition] = [
        Definition(id: "mem0", name: "Mem0", sourceTitle: "Mem0 OSS README", sourceURL: "https://github.com/mem0ai/mem0", publisher: "Mem0", license: "Apache-2.0", deployment: "Library, self-hosted server, or hosted platform", switchReason: "Automatic extraction and memory updates reduce the work of building a memory pipeline.", stayReason: "Hybrid retrieval, deduplication, and simple add/search/delete workflows keep adoption friction low.", limitation: "LLM and embedding configuration plus session isolation must be verified for each deployment."),
        Definition(id: "letta", name: "Letta", sourceTitle: "Letta Documentation", sourceURL: "https://docs.letta.com/", publisher: "Letta", license: nil, deployment: "Open-source agent harness and hosted platform", switchReason: "Developers want an agent whose working memory is visible and directly editable.", stayReason: "Core blocks, archival memory, and git-backed local memory provide explicit continuity.", limitation: "Persistent agent state needs strict workspace isolation and rollback controls."),
        Definition(id: "graphiti-zep", name: "Graphiti / Zep", sourceTitle: "Graphiti README", sourceURL: "https://github.com/getzep/graphiti", publisher: "Zep", license: nil, deployment: "Open-source graph framework or managed context service", switchReason: "Temporal facts and relationships answer questions that flat vector search misses.", stayReason: "Provenance, incremental graph updates, and historical retrieval support evolving data.", limitation: "Graphiti requires infrastructure choices; Zep's production engine is managed and proprietary."),
        Definition(id: "supermemory", name: "Supermemory", sourceTitle: "Supermemory README", sourceURL: "https://github.com/supermemoryai/supermemory", publisher: "Supermemory", license: "MIT", deployment: "Local/open components plus hosted context platform", switchReason: "One context stack can combine memory, RAG, profiles, connectors, and file processing.", stayReason: "Broad integrations and unified recall reduce the need to compose multiple services.", limitation: "Connector breadth and hosted workflows require careful local ownership and freshness controls."),
        Definition(id: "crewai-memory", name: "CrewAI Memory", sourceTitle: "CrewAI Memory Documentation", sourceURL: "https://github.com/crewAIInc/crewAI/blob/main/docs/v1.15.12/en/concepts/memory.mdx", publisher: "CrewAI", license: nil, deployment: "Open-source agent framework", switchReason: "A unified memory API is easier to adopt than separate short-term, long-term, and entity stores.", stayReason: "Scoped recall with semantic, recency, and importance scoring fits agent workflows.", limitation: "Memory analysis may send content to the configured LLM unless a local provider is used."),
        Definition(id: "cognee", name: "Cognee", sourceTitle: "Cognee Repository", sourceURL: "https://github.com/topoteretes/cognee", publisher: "Cognee", license: "Apache-2.0", deployment: "Self-hosted graph and vector memory platform", switchReason: "Ingestion, graph construction, vectors, and cited retrieval arrive as one workflow.", stayReason: "Graph-aware retrieval and provenance make domain knowledge easier to connect and inspect.", limitation: "The graph and storage stack adds operational complexity compared with an embedded SDK."),
        Definition(id: "khoj", name: "Khoj", sourceTitle: "Khoj Repository", sourceURL: "https://github.com/khoj-ai/khoj", publisher: "Khoj", license: "AGPL-3.0", deployment: "Self-hosted personal AI application or cloud", switchReason: "Users want a ready-to-use second brain rather than an SDK-only building block.", stayReason: "Document search, local models, web access, and multiple clients make it useful as a complete product.", limitation: "AGPL and application/server assumptions are not suitable for direct inclusion in this SDK."),
        Definition(id: "langmem", name: "LangMem", sourceTitle: "LangMem Documentation", sourceURL: "https://langchain-ai.github.io/langmem/", publisher: "LangChain", license: nil, deployment: "Open-source memory utilities", switchReason: "Teams can add memory management without adopting a complete memory platform.", stayReason: "Semantic, episodic, and procedural memory primitives remain flexible across workflows.", limitation: "The utilities are ecosystem-oriented and not a native Apple persistence layer."),
        Definition(id: "memobase", name: "Memobase", sourceTitle: "Memobase Repository", sourceURL: "https://github.com/memodb-io/memobase", publisher: "Memobase", license: "Apache-2.0", deployment: "Self-hosted profile memory server or cloud", switchReason: "Product teams need structured user profiles more than unrestricted agent memory.", stayReason: "Controllable profiles and time-aware user events keep personalization concise.", limitation: "The server, cache, and API-token model is outside the local Swift core."),
        Definition(id: "memu", name: "MemU", sourceTitle: "MemU Repository", sourceURL: "https://github.com/NevaMind-AI/memU", publisher: "NevaMind", license: "Apache-2.0", deployment: "Local or hosted proactive agent sidecar", switchReason: "Always-on agents need proactive memory without injecting the full history every turn.", stayReason: "Hierarchical, file-system-like memory supports cross-agent continuity.", limitation: "Proactive processing needs bounded cost, cancellation, and user-control policies."),
        Definition(id: "hindsight", name: "Hindsight", sourceTitle: "Hindsight Research", sourceURL: "https://aclanthology.org/2026.acl-demo.27.pdf", publisher: "Vectorize", license: nil, deployment: "Open-source agent memory system", switchReason: "Long-horizon agents benefit from retain, recall, and reflection rather than retrieval alone.", stayReason: "Reflection can improve future memory organization over repeated tasks.", limitation: "Reflection must remain auditable and must not silently rewrite trusted facts."),
        Definition(id: "proximakit", name: "ProximaKit", sourceTitle: "ProximaKit Repository", sourceURL: "https://github.com/vivekptnk/ProximaKit", publisher: "ProximaKit", license: "MIT in Archon's resolved dependency snapshot", deployment: "Pure Swift on-device vector index", switchReason: "Apple apps can keep semantic search local without a server or API key.", stayReason: "Durable HNSW search and on-device embeddings fit privacy-sensitive products.", limitation: "Adoption still requires device-scale recovery, memory, and migration evidence."),
        Definition(id: "recallkit", name: "RecallKit", sourceTitle: "RecallKit Repository", sourceURL: "https://github.com/gregyoung14/RecallKit", publisher: "RecallKit", license: "MIT", deployment: "iOS-first sparse local index", switchReason: "Apps need fast sparse search with bounded memory and predictable rebuilds.", stayReason: "Actor isolation, compaction, data protection, and storage adapters reduce operational risk.", limitation: "Sparse indexing complements rather than replaces semantic vector retrieval."),
        Definition(id: "wax", name: "Wax", sourceTitle: "Wax Repository", sourceURL: "https://github.com/christopherkarani/Wax", publisher: "Wax", license: nil, deployment: "Pure Swift single-file local memory", switchReason: "Developers want shared local agent memory with almost no setup.", stayReason: "No server, no API, and one local file create a very short path to first value.", limitation: "License, locking, recovery, and multi-process behavior require a fresh audit before adoption.")
    ]

}
