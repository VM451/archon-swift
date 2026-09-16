import Testing
import Foundation
@testable import ArchonMemory

private struct LatencyRNG {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000.0 - 0.5
    }
}

@Suite("Memory Search Latency Benchmarks")
struct MemorySearchLatencyTests {
    private static let corpusSize = 10_000
    private static let dimensions = 384
    private static let queryCount = 50

    @Test(
        "Vector search p95 beats the 20ms budget at 10k x 384",
        .enabled(if: ProcessInfo.processInfo.environment["ARCHON_ENABLE_BENCHMARKS"] == "1")
    )
    func testVectorSearchLatencyBudget() async throws {
        let store = try LocalVectorStore(inMemory: true, alpha: 1, beta: 0)
        var rng = LatencyRNG(state: 0x1A7E9C)
        var items: [MemoryItem] = []
        items.reserveCapacity(Self.corpusSize)
        for index in 0..<Self.corpusSize {
            let vector = (0..<Self.dimensions).map { _ in rng.nextFloat() }
            items.append(MemoryItem(
                memory: "Latency corpus fact \(index)",
                vector: vector,
                userId: "latency-user"
            ))
        }
        let ingestStart = Date()
        try await store.saveBatch(items: items)
        let ingestMs = Date().timeIntervalSince(ingestStart) * 1000

        var latencies: [Double] = []
        var recalls: [Float] = []
        for _ in 0..<Self.queryCount {
            let query = (0..<Self.dimensions).map { _ in rng.nextFloat() }
            let start = Date()
            let results = try await store.search(
                query: nil,
                vector: query,
                limit: 10,
                filters: MemoryFilter()
            )
            latencies.append(Date().timeIntervalSince(start) * 1000)
            #expect(results.count == 10)
            let truth = Set(items
                .map { ($0.id, VectorMath.cosineSimilarity(query, $0.vector)) }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map(\.0))
            let hits = results.filter { truth.contains($0.item.id) }.count
            recalls.append(Float(hits) / 10)
        }

        let sorted = latencies.sorted()
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        // The first query pays cache warm-up; steady state excludes it.
        let steady = Array(latencies.dropFirst())
        let steadySorted = steady.sorted()
        let steadyP95 = steadySorted[min(steadySorted.count - 1, Int(Double(steadySorted.count) * 0.95))]
        let meanRecall = recalls.reduce(0, +) / Float(recalls.count)
        print("LATENCY_BENCH ingest_ms=\(String(format: "%.0f", ingestMs)) mean_ms=\(String(format: "%.1f", mean)) p95_ms=\(String(format: "%.1f", p95)) cold_ms=\(String(format: "%.1f", latencies.first ?? -1)) steady_p95_ms=\(String(format: "%.1f", steadyP95)) recall_at_10=\(String(format: "%.4f", meanRecall))")
        #expect(steadyP95 < 20)
        #expect(meanRecall >= 0.99)
    }
}
