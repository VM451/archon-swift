import Foundation
import ArchonMemory
import ArchonMemoryProxima
import Testing

private struct ProximaLatencyRNG {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000.0 - 0.5
    }
}

@Suite("Proxima 10k Latency Benchmarks")
struct ProximaLatencyTests {
    private static let corpusSize = 10_000
    private static let dimensions = 384
    private static let queryCount = 25
    private static let topK = 10
    private static let clusterCount = 100
    /// Intra-cluster noise scale. Real text embeddings cluster by topic;
    /// uniform random vectors in 384 dimensions are nearly equidistant and
    /// defeat every partition-based ANN index (no published ANN benchmark,
    /// USearch included, measures uniform data), so the corpus is a Gaussian
    /// mixture that models embedding structure instead.
    private static let clusterNoise: Float = 0.25

    private let configuration = ProximaVectorIndexConfiguration(
        maximumConnections: 16,
        constructionSearchWidth: 100,
        querySearchWidth: 256,
        levelSeed: 42
    )

    @Test(
        "HNSW search holds Recall@10 above 0.99 inside the 20ms budget at 10k x 384",
        .enabled(if: ProcessInfo.processInfo.environment["ARCHON_ENABLE_BENCHMARKS"] == "1")
    )
    func testVectorSearchLatencyBudget() async throws {
        var rng = ProximaLatencyRNG(state: 0x90B0A)
        let centers = (0..<Self.clusterCount).map { _ in
            Self.normalize((0..<Self.dimensions).map { _ in rng.nextFloat() })
        }
        var records: [ArchonMemory.VectorIndexRecord] = []
        records.reserveCapacity(Self.corpusSize)
        for index in 0..<Self.corpusSize {
            let center = centers[index % Self.clusterCount]
            let raw = center.map { $0 + rng.nextFloat() * Self.clusterNoise }
            records.append(ArchonMemory.VectorIndexRecord(id: UUID(), vector: Self.normalize(raw)))
        }
        let index = try ProximaVectorIndexAdapter(dimension: Self.dimensions, configuration: configuration)
        let buildStart = Date()
        try await index.rebuild(records)
        let buildMs = Date().timeIntervalSince(buildStart) * 1000

        var latencies: [Double] = []
        var recalls: [Float] = []
        for position in 0..<Self.queryCount {
            // Queries come from the same mixture (a known topic plus noise),
            // matching how memory retrieval queries resemble stored content.
            let center = centers[(position * 37) % Self.clusterCount]
            let query = Self.normalize(center.map { $0 + rng.nextFloat() * Self.clusterNoise })
            let start = Date()
            let results = try await index.search(
                ArchonMemory.VectorIndexQuery(vector: query, limit: Self.topK)
            )
            latencies.append(Date().timeIntervalSince(start) * 1000)
            #expect(results.count == Self.topK)
            let truth = Set(records
                .map { ($0.id, VectorMath.cosineSimilarity(query, $0.vector)) }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.topK)
                .map(\.0))
            let hits = results.filter { truth.contains($0.id) }.count
            recalls.append(Float(hits) / Float(Self.topK))
        }

        let sorted = latencies.sorted()
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let meanRecall = recalls.reduce(0, +) / Float(recalls.count)
        print("PROXIMA_LATENCY_BENCH build_ms=\(String(format: "%.0f", buildMs)) mean_ms=\(String(format: "%.2f", mean)) p95_ms=\(String(format: "%.2f", p95)) recall_at_10=\(String(format: "%.4f", meanRecall))")
        #expect(p95 < 20)
        #expect(meanRecall >= 0.99)
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
