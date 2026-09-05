import Foundation

/// Configuration options for initializing ArchonClient. Default values prioritize Apple Foundation Models & CloudKit.
public struct ArchonConfig: Sendable {
    public var llmProvider: LLMProvider
    public var embeddingProvider: EmbeddingProvider
    public var customVectorStore: VectorStore?
    public var customGraphStore: GraphStore?
    public var cloudKitContainerId: String?
    public var enableAutoSync: Bool
    public var enableSpotlightIndexing: Bool
    public var databasePath: String?
    public var customExtractionPrompt: String?
    public var extractionPolicy: MemoryExtractionPolicy
    public var retrievalPolicy: MemoryRetrievalPolicy

    public init(
        llmProvider: LLMProvider = AppleFoundationModelProvider(),
        embeddingProvider: EmbeddingProvider = AppleFoundationModelProvider(),
        customVectorStore: VectorStore? = nil,
        customGraphStore: GraphStore? = nil,
        cloudKitContainerId: String? = nil,
        enableAutoSync: Bool = true,
        enableSpotlightIndexing: Bool = true,
        databasePath: String? = nil,
        customExtractionPrompt: String? = nil,
        extractionPolicy: MemoryExtractionPolicy = .standard,
        retrievalPolicy: MemoryRetrievalPolicy = .standard
    ) {
        self.llmProvider = llmProvider
        self.embeddingProvider = embeddingProvider
        self.customVectorStore = customVectorStore
        self.customGraphStore = customGraphStore
        self.cloudKitContainerId = cloudKitContainerId
        self.enableAutoSync = enableAutoSync
        self.enableSpotlightIndexing = enableSpotlightIndexing
        self.databasePath = databasePath
        self.customExtractionPrompt = customExtractionPrompt
        self.extractionPolicy = extractionPolicy
        self.retrievalPolicy = retrievalPolicy
    }
}
