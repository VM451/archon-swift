import Foundation
import Testing
@testable import ArchonMemory

@Suite("Competitive Research Memory Tests")
struct CompetitiveResearchTests {
    private func makeClient(vectorStore: VectorStore) async throws -> ArchonClient {
        try await ArchonClient(config: ArchonConfig(
            llmProvider: MockLLMProvider(),
            embeddingProvider: MockEmbeddingProvider(vectorDimension: 32),
            customVectorStore: vectorStore,
            customGraphStore: try LocalGraphStore(inMemory: true),
            enableAutoSync: false,
            enableSpotlightIndexing: false
        ))
    }

    @Test("Seed snapshots have stable identities and cover the 14-provider landscape")
    func seedIsStable() {
        let first = CompetitiveResearchSeed.initialSnapshots()
        let second = CompetitiveResearchSeed.initialSnapshots()

        #expect(first.count == 14)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.flatMap(\.insights).map(\.id) == second.flatMap(\.insights).map(\.id))
        #expect(first.allSatisfy { $0.insights.count == 2 })
    }

    @Test("Competitive insights persist through restart and remain searchable")
    func insightsRehydrateAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("memory.sqlite").path
        let snapshot = try #require(CompetitiveResearchSeed.initialSnapshots().first)

        let firstStore = try LocalVectorStore(databasePath: databasePath)
        let firstClient = try await makeClient(vectorStore: firstStore)
        let report = try await firstClient.ingestCompetitiveResearch(snapshot)
        #expect(report.insightCount == 2)
        #expect(report.profileStored)

        let firstMatches = try await firstClient.searchCompetitiveInsights(
            query: "automatic extraction deduplication",
            limit: 5,
            filter: CompetitiveInsightFilter(providerID: snapshot.providerID, kinds: [.stayReason])
        )
        #expect(firstMatches.count == 1)
        #expect(firstMatches.first?.insight.sourceIDs == [snapshot.sources[0].id])

        let sourceMatches = try await firstClient.searchCompetitiveInsights(
            query: "automatic extraction deduplication",
            limit: 5,
            filter: CompetitiveInsightFilter(sourceID: snapshot.sources[0].id, kinds: [.stayReason])
        )
        #expect(sourceMatches.count == 1)

        let secondStore = try LocalVectorStore(databasePath: databasePath)
        let secondClient = try await makeClient(vectorStore: secondStore)
        let secondMatches = try await secondClient.searchCompetitiveInsights(
            query: "automatic extraction deduplication",
            limit: 5,
            filter: CompetitiveInsightFilter(providerID: snapshot.providerID, kinds: [.stayReason])
        )
        #expect(secondMatches.count == 1)
        #expect(secondMatches.first?.insight.id == firstMatches.first?.insight.id)
        #expect(await secondClient.providerProfile(for: snapshot.providerID) != nil)
        #expect(await secondClient.competitiveResearchSnapshots().first?.sources.first?.title == snapshot.sources.first?.title)
        #expect(await secondClient.competitiveResearchSnapshots().first?.sources.first?.license == "Apache-2.0")

        _ = try await secondClient.ingestCompetitiveResearch(snapshot)
        let documents = try await secondStore.fetchAllDocuments(userId: nil)
        #expect(documents.count == 4)
        let exported = try await secondClient.export()
        let export = try JSONDecoder().decode(ArchonMemoryExport.self, from: exported)
        #expect(export.documents.count == 4)
        #expect(export.competitiveResearchSnapshots.count == 1)
        #expect(export.competitiveResearchSnapshots.first?.sources.first?.license == "Apache-2.0")

        let staleInsight = CompetitiveInsight(
            id: snapshot.insights[1].id,
            providerID: snapshot.providerID,
            providerName: snapshot.providerName,
            kind: .stayReason,
            claim: "This stale claim must not replace the newer snapshot.",
            sourceIDs: [snapshot.sources[0].id],
            sourceURLs: [snapshot.sources[0].url],
            confidence: .high,
            validFrom: snapshot.retrievedAt.addingTimeInterval(-86_400)
        )
        let staleSnapshot = CompetitiveResearchSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            providerName: snapshot.providerName,
            userId: snapshot.userId,
            retrievedAt: snapshot.retrievedAt.addingTimeInterval(-86_400),
            sources: snapshot.sources,
            profile: snapshot.profile,
            insights: [staleInsight]
        )
        let staleReport = try await secondClient.ingestCompetitiveResearch(staleSnapshot)
        #expect(staleReport.insightCount == 0)
        let retained = try await secondClient.searchCompetitiveInsights(
            query: "automatic extraction deduplication",
            limit: 5,
            filter: CompetitiveInsightFilter(providerID: snapshot.providerID, kinds: [.stayReason])
        )
        #expect(retained.first?.insight.claim == snapshot.insights[1].claim)
    }

    @Test("Document metadata and knowledge-base filters survive persistence")
    func documentMetadataAndFilters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("research.md")
        try Data("# Research\nTemporal provenance and source links matter.".utf8).write(to: fileURL)

        let store = try LocalVectorStore(inMemory: true)
        let client = try await makeClient(vectorStore: store)
        _ = try await client.ingestDocument(fileURL: fileURL, tags: ["research"])

        let documents = try await client.searchDocuments(query: "source links", limit: 5)
        #expect(documents.first?.metadata["_archon.mimeType"] == "text/markdown")

        let results = try await client.searchKnowledgeBase(
            query: "temporal provenance",
            limit: 5,
            filter: DocumentFilter(
                tags: ["research"],
                mimeType: "text/markdown",
                sourceURLPrefix: "file://"
            )
        )
        #expect(!results.isEmpty)
    }

    @Test("Feedback is local, durable, and query limits fail closed")
    func feedbackAndLimits() async throws {
        let store = try LocalVectorStore(inMemory: true)
        let client = try await makeClient(vectorStore: store)
        let snapshot = try #require(CompetitiveResearchSeed.initialSnapshots().first)
        _ = try await client.ingestCompetitiveResearch(snapshot)
        let insight = try #require(snapshot.insights.first)

        let event = MemoryFeedbackEvent(insightID: insight.id, kind: .accepted, userId: "user-1")
        try await client.recordFeedback(event)
        let feedback = try await client.feedback(insightID: insight.id, userId: "user-1")
        #expect(feedback.count == 1)
        #expect(feedback.first?.id == event.id)
        #expect(feedback.first?.insightID == event.insightID)
        #expect(feedback.first?.kind == event.kind)
        #expect(feedback.first?.userId == event.userId)

        do {
            _ = try await client.searchDocuments(query: "memory", limit: -1)
            Issue.record("Expected a negative document limit to fail.")
        } catch let error as ArchonMemoryError {
            #expect(error == .invalidSearchRequest("limit must be non-negative"))
        }

        do {
            _ = try await client.recall(limit: -1)
            Issue.record("Expected a negative recall limit to fail.")
        } catch let error as ArchonMemoryError {
            #expect(error == .invalidSearchRequest("limit must be non-negative"))
        }
    }
}
