import Testing
@testable import ArchonAgent

private actor TestPreparationAdapter: ModelPreparationBenchmarkAdapter {
    let runtimeName = "Test runtime"
    let artifactIdentifier = "test-artifact"

    private(set) var prepareCount = 0
    private(set) var unloadCount = 0

    func prepare() async throws {
        prepareCount += 1
    }

    func unload() async {
        unloadCount += 1
    }
}

@Suite("Model Preparation Benchmark Tests")
struct ModelPreparationBenchmarkTests {
    @Test("Measures preparations and unloads after every sample")
    func measuresAndUnloadsEachSample() async throws {
        let adapter = TestPreparationAdapter()
        let report = try await ModelPreparationBenchmarkRunner().run(
            adapter: adapter,
            configuration: ModelPreparationBenchmarkConfiguration(
                iterations: 2,
                warmupIterations: 1
            )
        )

        #expect(report.runtimeName == "Test runtime")
        #expect(report.artifactIdentifier == "test-artifact")
        #expect(report.sampleSeconds.count == 2)
        #expect(report.iterations == 2)
        #expect(report.warmupIterations == 1)
        #expect(report.minimumSeconds <= report.medianSeconds)
        #expect(report.medianSeconds <= report.maximumSeconds)
        #expect(await adapter.prepareCount == 3)
        #expect(await adapter.unloadCount == 3)
    }

    @Test("Clamps invalid iteration counts to a runnable benchmark")
    func clampsConfiguration() {
        let configuration = ModelPreparationBenchmarkConfiguration(
            iterations: 0,
            warmupIterations: -4
        )

        #expect(configuration.iterations == 1)
        #expect(configuration.warmupIterations == 0)
    }
}
