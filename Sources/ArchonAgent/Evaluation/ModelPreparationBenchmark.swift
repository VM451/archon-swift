import Foundation

/// A runtime adapter used by `ModelPreparationBenchmarkRunner`.
///
/// The adapter owns the framework-specific model contract. The runner only
/// measures real preparation and releases the adapter between samples; it never
/// fabricates token counts or inference throughput.
public protocol ModelPreparationBenchmarkAdapter: Sendable {
    var runtimeName: String { get }
    var artifactIdentifier: String { get }

    func prepare() async throws
    func unload() async
}

public struct ModelPreparationBenchmarkConfiguration: Sendable, Codable, Equatable {
    public let iterations: Int
    public let warmupIterations: Int

    public init(iterations: Int = 3, warmupIterations: Int = 1) {
        self.iterations = max(1, iterations)
        self.warmupIterations = max(0, warmupIterations)
    }
}

public struct ModelPreparationBenchmarkReport: Sendable, Codable, Equatable {
    public let runtimeName: String
    public let artifactIdentifier: String
    public let warmupIterations: Int
    public let iterations: Int
    public let sampleSeconds: [Double]
    public let minimumSeconds: Double
    public let medianSeconds: Double
    public let maximumSeconds: Double

    public init(
        runtimeName: String,
        artifactIdentifier: String,
        warmupIterations: Int,
        iterations: Int,
        sampleSeconds: [Double]
    ) {
        let samples = sampleSeconds.sorted()
        self.runtimeName = runtimeName
        self.artifactIdentifier = artifactIdentifier
        self.warmupIterations = warmupIterations
        self.iterations = iterations
        self.sampleSeconds = sampleSeconds
        self.minimumSeconds = samples.first ?? 0
        self.maximumSeconds = samples.last ?? 0
        if samples.isEmpty {
            self.medianSeconds = 0
        } else {
            let middle = samples.count / 2
            self.medianSeconds = samples.count.isMultiple(of: 2)
                ? (samples[middle - 1] + samples[middle]) / 2
                : samples[middle]
        }
    }
}

public enum ModelPreparationBenchmarkError: Error, LocalizedError, Sendable, Equatable {
    case noSamples

    public var errorDescription: String? {
        switch self {
        case .noSamples:
            return "The model preparation benchmark produced no samples."
        }
    }
}

/// Measures a concrete runtime adapter with a monotonic clock.
public struct ModelPreparationBenchmarkRunner: Sendable {
    public init() {}

    public func run(
        adapter: any ModelPreparationBenchmarkAdapter,
        configuration: ModelPreparationBenchmarkConfiguration = ModelPreparationBenchmarkConfiguration()
    ) async throws -> ModelPreparationBenchmarkReport {
        for _ in 0..<configuration.warmupIterations {
            do {
                try await adapter.prepare()
            } catch {
                await adapter.unload()
                throw error
            }
            await adapter.unload()
        }

        var samples: [Double] = []
        samples.reserveCapacity(configuration.iterations)
        for _ in 0..<configuration.iterations {
            let start = ContinuousClock.now
            do {
                try await adapter.prepare()
                let duration = start.duration(to: .now)
                samples.append(Self.seconds(from: duration))
            } catch {
                await adapter.unload()
                throw error
            }
            await adapter.unload()
        }

        guard !samples.isEmpty else { throw ModelPreparationBenchmarkError.noSamples }
        return ModelPreparationBenchmarkReport(
            runtimeName: adapter.runtimeName,
            artifactIdentifier: adapter.artifactIdentifier,
            warmupIterations: configuration.warmupIterations,
            iterations: configuration.iterations,
            sampleSeconds: samples
        )
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
