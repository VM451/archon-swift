import CryptoKit
import Foundation
import Testing
@testable import ArchonModels
import ArchonCore

// MARK: - Fakes

private struct ScriptedResponse: Sendable {
    var body: Data = Data()
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var streamError: Error? = nil
}

private final class ScriptedByteServer: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var handler: @Sendable (URLRequest, Int) -> ScriptedResponse

    init(handler: @escaping @Sendable (URLRequest, Int) -> ScriptedResponse) {
        self.handler = handler
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    var lastRangeHeader: String? {
        lock.withLock { requests.last?.value(forHTTPHeaderField: "Range") }
    }

    var requestedURLs: [URL?] {
        lock.withLock { requests.map(\.url) }
    }

    func provider() -> ModelByteStreamProvider {
        { @Sendable request in
            let index = self.lock.withLock { () -> Int in
                self.requests.append(request)
                return self.requests.count - 1
            }
            let script = self.handler(request, index)
            guard (200...299).contains(script.statusCode) else {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: script.statusCode,
                    httpVersion: nil,
                    headerFields: script.headers
                )!
                let stream = AsyncThrowingStream<UInt8, Error> { $0.finish() }
                return (stream, response)
            }
            let start = request.value(forHTTPHeaderField: "Range")
                .flatMap { $0.split(separator: "=").last?.split(separator: "-").first }
                .flatMap { Int64($0) } ?? 0
            let body = Data(script.body.dropFirst(Int(max(start, 0))))
            var headers = script.headers
            let status: Int
            if start > 0 {
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(Int64(script.body.count) - 1)/\(script.body.count)"
            } else {
                status = 200
            }
            headers["Content-Length"] = String(body.count)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            let streamError = script.streamError
            let stream = AsyncThrowingStream<UInt8, Error> { continuation in
                for byte in body { continuation.yield(byte) }
                if let streamError {
                    continuation.finish(throwing: streamError)
                } else {
                    continuation.finish()
                }
            }
            return (stream, response)
        }
    }
}

private struct StubHTTPClient: ModelHTTPClient {
    let payload: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw ArchonModelsError.invalidResponse
        }
        return (payload, response)
    }
}

private func stackTestDevice() -> ArchonDeviceCapabilities {
    ArchonDeviceCapabilities(
        platform: .macOS,
        osVersion: ArchonOSVersion(major: 27),
        physicalMemoryBytes: 16_000_000_000,
        availableMemoryBytes: 12_000_000_000,
        processorCount: 8,
        deviceArchitecture: "arm64",
        supportsAppleFoundationModels: true,
        supportsCoreAI: true
    )
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@Suite("Models Stack Tests")
struct ModelsStackTests {
    // MARK: Prep recipes

    @Test("Recipe matrix covers raw sources to runnable runtimes")
    func recipeMatrix() throws {
        let sources: [ArchonModelFormat] = [.gguf, .safetensors, .transformers]
        let targets: [ArchonModelRuntime] = [.mlx, .coreAI]
        for source in sources {
            for target in targets {
                let recipe = try #require(ModelPrepRecipeIndex.recipe(source: source, target: target))
                #expect(recipe.family == nil)
                #expect(recipe.isValid)
                #expect(recipe.sourceFormats == [source])
                #expect(recipe.targetRuntime == target)
                #expect(!recipe.steps.isEmpty)
                #expect(!recipe.tooling.isEmpty)
                #expect(recipe.validatesToManifest)
            }
        }
        #expect(ModelPrepRecipeIndex.neutralRecipes.count == 6)
        let allNeutralValid = ModelPrepRecipeIndex.neutralRecipes.allSatisfy { $0.isValid }
        #expect(allNeutralValid)
    }

    @Test("Known families get tuned recipes; unknown families fail closed")
    func recipeFamilyHandling() throws {
        let neutral = try #require(ModelPrepRecipeIndex.recipe(source: .gguf, target: .mlx))
        let tuned = try #require(ModelPrepRecipeIndex.recipe(source: .gguf, target: .mlx, family: "Qwen"))
        #expect(tuned.family == "Qwen")
        #expect(tuned.isValid)
        #expect(tuned.steps.count == neutral.steps.count + 1)
        #expect(tuned.tooling == neutral.tooling)

        #expect(ModelPrepRecipeIndex.recipe(source: .gguf, target: .mlx, family: "Klingon") == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .safetensors, target: .coreAI, family: "  ") != nil)
    }

    @Test("Recipe lookup rejects runnable sources and non-local targets")
    func recipeRejectsRunnable() {
        #expect(ModelPrepRecipeIndex.recipe(source: .mlx, target: .mlx) == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .aimodel, target: .coreAI) == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .gguf, target: .remote) == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .gguf, target: .foundationModels) == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .gguf, target: .unknown) == nil)
        #expect(ModelPrepRecipeIndex.recipe(source: .unknown, target: .mlx) == nil)
    }

    @Test("Invalid recipes fail validation")
    func recipeValidation() {
        let runnableSource = ModelPrepRecipe(
            sourceFormats: [.mlx],
            targetRuntime: .mlx,
            steps: ["step"],
            tooling: ["tool"]
        )
        #expect(!runnableSource.isValid)
        let emptySteps = ModelPrepRecipe(
            sourceFormats: [.gguf],
            targetRuntime: .mlx,
            steps: [],
            tooling: ["tool"]
        )
        #expect(!emptySteps.isValid)
        let badFamily = ModelPrepRecipe(
            sourceFormats: [.gguf],
            targetRuntime: .mlx,
            family: "  ",
            steps: ["step"],
            tooling: ["tool"]
        )
        #expect(!badFamily.isValid)
    }

    @Test("Runtime still rejects raw weights as runnable")
    func runtimeRejectsRaw() async throws {
        let device = stackTestDevice()
        let raw = ModelVariant(
            id: "raw-gguf",
            name: "model.gguf",
            modelID: "example/raw",
            source: .huggingFace,
            format: .gguf,
            runtime: .unknown,
            estimatedMemoryBytes: 100
        )
        let compatibility = ModelCompatibilityAnalyzer.analyze(variant: raw, device: device)
        #expect(compatibility.status == .conversionRequired)
        #expect(!compatibility.canLoad)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ggufURL = root.appendingPathComponent("model.gguf")
        try Data("gguf-weights".utf8).write(to: ggufURL)
        let inspection = try ModelArtifactInspector.inspect(at: ggufURL)
        #expect(inspection.format == .gguf)
        #expect(inspection.requiresConversion)
        #expect(!inspection.isRunnable)

        let runnable = ModelVariant(
            id: "ready-mlx",
            name: "model.mlx",
            modelID: "example/ready",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )
        let catalog = MLXModelCatalog(provider: StaticModelCatalog(models: [
            ModelDescriptor(id: "example/raw", name: "Raw", publisher: "Example", source: .huggingFace, variants: [raw]),
            ModelDescriptor(id: "example/ready", name: "Ready", publisher: "Example", source: .localImport, variants: [runnable])
        ]))
        let results = try await catalog.search(ModelSearchRequest(query: "", limit: 10))
        #expect(results.map(\.id) == ["example/ready"])
        #expect(results.first?.variants.map(\.format) == [.mlx])
    }

    // MARK: Download policy bounds

    @Test("Download policy clamps attempts and backoff")
    func downloadPolicyBounds() {
        #expect(ModelDownloadPolicy(maxAttempts: 0).maxAttempts == 1)
        #expect(ModelDownloadPolicy(maxAttempts: 99).maxAttempts == ModelDownloadPolicy.maximumAllowedAttempts)
        #expect(ModelDownloadPolicy.maximumAllowedAttempts == 10)
        #expect(ModelDownloadPolicy.maximumRetryBackoff == 60)

        let policy = ModelDownloadPolicy(maxAttempts: 3, initialBackoff: 1, maximumBackoff: 30)
        #expect(policy.backoffDelay(forRetryIndex: 0) == 0)
        #expect(policy.backoffDelay(forRetryIndex: 1) == 1)
        #expect(policy.backoffDelay(forRetryIndex: 2) == 2)
        #expect(policy.backoffDelay(forRetryIndex: 3) == 4)
        #expect(policy.backoffDelay(forRetryIndex: 10) == 30)
    }

    // MARK: Attempt / resume / retry transparency

    @Test("Foreground progress carries attempt info")
    func progressCarriesAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-attempt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 0x41, count: 1024)
        let server = ScriptedByteServer { _, _ in ScriptedResponse(body: body) }
        let variant = ModelVariant(
            id: "attempt-model",
            name: "model.aimodel",
            modelID: "example/attempt",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/attempt.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(body.count),
            sha256: sha256Hex(body)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 3, initialBackoff: 0),
            byteStreamProvider: server.provider()
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Attempt"),
            into: library,
            on: stackTestDevice()
        )
        var attempts: [ModelDownloadAttempt] = []
        var sawReady = false
        for try await event in events {
            if case .downloading(_, _, _, let attempt) = event.state, let attempt {
                attempts.append(attempt)
            }
            if case .ready = event.state { sawReady = true }
        }
        #expect(sawReady)
        #expect(!attempts.isEmpty)
        for attempt in attempts {
            #expect(attempt.attempt == 1)
            #expect(attempt.maxAttempts == 3)
            #expect(attempt.resumedFromBytes == nil)
            #expect(attempt.deltaReusedBytes == nil)
        }
    }

    @Test("Transient failure retries within the bounded cap and surfaces the try")
    func transientFailureRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 0x42, count: 512)
        let server = ScriptedByteServer { _, index in
            if index == 0 {
                return ScriptedResponse(statusCode: 503)
            }
            return ScriptedResponse(body: body)
        }
        let variant = ModelVariant(
            id: "retry-model",
            name: "model.aimodel",
            modelID: "example/retry",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/retry.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(body.count)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 3, initialBackoff: 0),
            byteStreamProvider: server.provider()
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Retry"),
            into: library,
            on: stackTestDevice()
        )
        var tryNumbers: [Int] = []
        var sawReady = false
        for try await event in events {
            if case .downloading(_, _, _, let attempt) = event.state, let attempt {
                tryNumbers.append(attempt.attempt)
            }
            if case .ready = event.state { sawReady = true }
        }
        #expect(sawReady)
        #expect(server.requestCount == 2)
        #expect(tryNumbers.allSatisfy { $0 == 2 })
        #expect(!tryNumbers.isEmpty)
    }

    @Test("Exhausted retries fail with the bounded try count")
    func exhaustedRetriesFailBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-exhaust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ScriptedByteServer { _, _ in ScriptedResponse(statusCode: 503) }
        let variant = ModelVariant(
            id: "exhaust-model",
            name: "model.aimodel",
            modelID: "example/exhaust",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/exhaust.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            estimatedMemoryBytes: 100
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 2, initialBackoff: 0),
            byteStreamProvider: server.provider()
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Exhaust"),
            into: library,
            on: stackTestDevice()
        )
        var failedAttempt: ModelDownloadAttempt?
        do {
            for try await event in events {
                if case .failed(_, let attempt) = event.state { failedAttempt = attempt }
            }
            Issue.record("Expected the exhausted download to throw.")
        } catch {
            #expect(error is ArchonModelsError)
        }
        #expect(server.requestCount == 2)
        let attempt = try #require(failedAttempt)
        #expect(attempt.attempt == 2)
        #expect(attempt.maxAttempts == 2)
        #expect(attempt.lastError != nil)
    }

    @Test("Retry preserves staging while redownload clears it")
    func retryPreservesStagingRedownloadClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x43, count: 70_000)
        let server = ScriptedByteServer { _, index in
            if index == 0 {
                // Yield one full 64 KiB flush, then fail mid-stream.
                return ScriptedResponse(
                    body: Data(payload.prefix(65_536)),
                    streamError: URLError(.networkConnectionLost)
                )
            }
            return ScriptedResponse(body: payload)
        }
        let variant = ModelVariant(
            id: "staging-model",
            name: "model.aimodel",
            modelID: "example/staging",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/staging.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(payload.count),
            sha256: sha256Hex(payload)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: server.provider()
        )
        let first = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Staging"),
            into: library,
            on: stackTestDevice()
        )
        var sawFailed = false
        do {
            for try await event in first {
                if case .failed = event.state { sawFailed = true }
            }
        } catch {}
        #expect(sawFailed)

        let stagingURL = try await library.stagingURL(for: variant)
        let stagedSize = (try? FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        #expect(stagedSize == 65_536)

        // Retry resumes from the preserved staging offset.
        let retried = try await manager.retry(variantID: variant.id, into: library, on: stackTestDevice())
        var resumedOffset: Int64?
        var sawReady = false
        for try await event in retried {
            if case .downloading(_, _, _, let attempt) = event.state {
                resumedOffset = attempt?.resumedFromBytes ?? resumedOffset
            }
            if case .ready = event.state { sawReady = true }
        }
        #expect(sawReady)
        #expect(server.lastRangeHeader == "bytes=65536-")
        #expect(resumedOffset == 65_536)

        // A fresh variant through the same manager proves redownload clears.
        let variant2 = ModelVariant(
            id: "staging-model-2",
            name: "model2.aimodel",
            modelID: "example/staging2",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/staging2.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(payload.count)
        )
        let server2 = ScriptedByteServer { _, index in
            if index == 0 {
                return ScriptedResponse(body: Data(payload.prefix(65_536)), streamError: URLError(.networkConnectionLost))
            }
            return ScriptedResponse(body: payload)
        }
        let manager2 = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: server2.provider()
        )
        let library2 = ModelLibrary(rootURL: root.appendingPathComponent("library2"))
        let failing = try await manager2.download(
            ModelDownloadRequest(variant: variant2, modelName: "Staging 2"),
            into: library2,
            on: stackTestDevice()
        )
        do {
            for try await _ in failing {}
        } catch {}
        let staging2 = try await library2.stagingURL(for: variant2)
        #expect(FileManager.default.fileExists(atPath: staging2.path))
        let redownloaded = try await manager2.redownload(variantID: variant2.id, into: library2, on: stackTestDevice())
        var redownloadedOffset: Int64? = -1
        var redownloadedReady = false
        for try await event in redownloaded {
            if case .downloading(_, _, _, let attempt) = event.state {
                redownloadedOffset = attempt?.resumedFromBytes
            }
            if case .ready = event.state { redownloadedReady = true }
        }
        #expect(redownloadedReady)
        #expect(server2.lastRangeHeader == nil)
        #expect(redownloadedOffset == nil)
    }

    @Test("Delta bookkeeping reports verified complete resources")
    func deltaBookkeeping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-delta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file1 = Data(repeating: 0x44, count: 2048)
        let file2 = Data(repeating: 0x45, count: 1024)
        let url1 = URL(string: "https://models.example.test/pkg/file1.bin")!
        let url2 = URL(string: "https://models.example.test/pkg/file2.bin")!
        let server = ScriptedByteServer { _, _ in ScriptedResponse(body: file2) }
        let variant = ModelVariant(
            id: "delta-model",
            name: "package",
            modelID: "example/delta",
            source: .directURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(file1.count + file2.count),
            sha256: nil,
            resources: [
                ModelResource(name: "file1.bin", url: url1, relativePath: "file1.bin", sizeBytes: Int64(file1.count)),
                ModelResource(name: "file2.bin", url: url2, relativePath: "file2.bin", sizeBytes: Int64(file2.count), sha256: sha256Hex(file2))
            ]
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        // Pre-stage file1 as verified-complete; the run must skip it.
        let staging = try await library.stagingURL(for: variant)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try file1.write(to: staging.appendingPathComponent("file1.bin"))

        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: server.provider()
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Delta"),
            into: library,
            on: stackTestDevice()
        )
        var reused: [Int64] = []
        var sawReady = false
        for try await event in events {
            if case .downloading(_, _, _, let attempt) = event.state,
               let delta = attempt?.deltaReusedBytes {
                reused.append(delta)
            }
            if case .ready = event.state { sawReady = true }
        }
        #expect(sawReady)
        #expect(server.requestCount == 1)
        #expect(server.requestedURLs == [url2])
        #expect(reused.allSatisfy { $0 == Int64(file1.count) })
        #expect(!reused.isEmpty)
    }

    // MARK: Benchmark routing

    @Test("Measured family benchmarks upgrade the quality fallback after fit")
    func benchmarkRouting() {
        let device = stackTestDevice()
        let unrated = ModelVariant(
            id: "unrated-mlx",
            name: "unrated.mlx",
            modelID: "example/qwen",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )
        let ratedLow = ModelVariant(
            id: "rated-low-mlx",
            name: "rated-low.mlx",
            modelID: "example/qwen",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100,
            estimatedQualityScore: 0.5,
            estimatedTokensPerSecond: 10
        )
        let tooBig = ModelVariant(
            id: "too-big-mlx",
            name: "too-big.mlx",
            modelID: "example/qwen",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 1_000_000_000_000
        )
        let model = ModelDescriptor(
            id: "example/qwen",
            name: "Qwen",
            publisher: "Qwen",
            family: "Qwen",
            source: .localImport,
            variants: [unrated, ratedLow, tooBig]
        )
        // Without measurements the declared estimate wins.
        #expect(ModelCompatibilityAnalyzer.recommendedVariant(for: model, device: device)?.id == "rated-low-mlx")
        // With a measured family record the unrated variant wins on measured quality.
        let measured = ModelFamilyBenchmark(family: "qwen", quality: 0.9, tokensPerSecond: 42, measuredOn: "mac-16gb")
        #expect(measured.isValid)
        let picked = ModelCompatibilityAnalyzer.recommendedVariant(
            for: model,
            device: device,
            benchmarks: [measured]
        )
        #expect(picked?.id == "unrated-mlx")
        // Fit still dominates: the too-big variant never wins.
        #expect(picked?.id != "too-big-mlx")
    }

    @Test("Invalid benchmark records are ignored and ties stay deterministic")
    func benchmarkInvalidAndTies() {
        let device = stackTestDevice()
        let variantA = ModelVariant(
            id: "a-variant",
            name: "a.mlx",
            modelID: "example/tie",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )
        let variantB = ModelVariant(
            id: "b-variant",
            name: "b.mlx",
            modelID: "example/tie",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )
        let model = ModelDescriptor(
            id: "example/tie",
            name: "Tie",
            publisher: "Example",
            family: "Qwen",
            source: .localImport,
            variants: [variantB, variantA]
        )
        let invalid: [ModelFamilyBenchmark] = [
            ModelFamilyBenchmark(family: "Qwen", quality: 5.0),
            ModelFamilyBenchmark(family: "Qwen", quality: .nan),
            ModelFamilyBenchmark(family: "", quality: 0.9),
            ModelFamilyBenchmark(family: "Qwen", quality: 0.9, tokensPerSecond: -1),
            ModelFamilyBenchmark(family: String(repeating: "q", count: 65), quality: 0.9)
        ]
        #expect(invalid.allSatisfy { !$0.isValid })
        // A valid record for another family is ignored just like invalid ones.
        let otherFamily = ModelFamilyBenchmark(family: "Llama", quality: 0.99)
        #expect(otherFamily.isValid)
        #expect(ModelCompatibilityAnalyzer.measuredBenchmark(forFamily: "Qwen", explicit: invalid + [otherFamily]) == nil)
        // Invalid records ignored: deterministic id tiebreak decides.
        let picked = ModelCompatibilityAnalyzer.recommendedVariant(for: model, device: device, benchmarks: invalid + [otherFamily])
        #expect(picked?.id == "a-variant")

        // Explicit records beat descriptor-carried records.
        let carried = ModelDescriptor(
            id: "example/carried",
            name: "Carried",
            publisher: "Example",
            family: "Qwen",
            source: .localImport,
            variants: [variantA],
            benchmarks: [ModelFamilyBenchmark(family: "Qwen", quality: 0.1, measuredOn: "carried")]
        )
        let explicit = ModelFamilyBenchmark(family: "Qwen", quality: 0.8, measuredOn: "explicit")
        let resolved = ModelCompatibilityAnalyzer.measuredBenchmark(
            forFamily: carried.family,
            explicit: [explicit],
            carried: carried.benchmarks
        )
        #expect(resolved?.measuredOn == "explicit")
        #expect(ModelCompatibilityAnalyzer.measuredBenchmark(forFamily: nil, explicit: [explicit]) == nil)
    }

    // MARK: Validator bounds for new fields

    @Test("Manifest validator bounds the family field")
    func manifestFamilyBounds() {
        let base = ArchonModelManifest(
            modelID: "example/family",
            modelName: "Family",
            runtime: .mlx,
            format: .mlx,
            supportedDeviceArchitectures: ["arm64"]
        )
        #expect(ModelManifestValidator.validate(base).isValid)
        #expect(ModelManifestValidator.validate(ArchonModelManifest(
            modelID: "example/family",
            modelName: "Family",
            family: "Qwen",
            runtime: .mlx,
            format: .mlx,
            supportedDeviceArchitectures: ["arm64"]
        )).isValid)
        let blank = ArchonModelManifest(
            modelID: "example/family",
            modelName: "Family",
            family: "  ",
            runtime: .mlx,
            format: .mlx
        )
        #expect(ModelManifestValidator.validate(blank).errors.contains { $0.contains("family") })
        let oversized = ArchonModelManifest(
            modelID: "example/family",
            modelName: "Family",
            family: String(repeating: "q", count: 65),
            runtime: .mlx,
            format: .mlx
        )
        #expect(ModelManifestValidator.validate(oversized).errors.contains { $0.contains("family") })
    }

    @Test("Manifests without a family decode with nil")
    func manifestFamilyDecoding() throws {
        let base = ArchonModelManifest(
            modelID: "example/legacy",
            modelName: "Legacy",
            runtime: .mlx,
            format: .mlx
        )
        let data = try JSONEncoder().encode(base)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "family")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ArchonModelManifest.self, from: legacy)
        #expect(decoded.family == nil)
    }

    // MARK: Storage breakdown

    @Test("Storage breakdown math splits installed, staging, and temp bytes")
    func storageBreakdownMath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDir = root.appendingPathComponent("modelA", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let weights = Data(repeating: 0x46, count: 4096)
        try weights.write(to: modelDir.appendingPathComponent("weights.bin"))
        let manifest = ArchonModelManifest(
            modelID: "example/modelA",
            modelName: "Model A",
            runtime: .mlx,
            format: .mlx,
            artifactPath: "weights.bin"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: modelDir.appendingPathComponent(ArchonModelManifest.filename))
        let manifestSize = try Data(contentsOf: modelDir.appendingPathComponent(ArchonModelManifest.filename)).count

        let stagingDir = root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 512).write(to: stagingDir.appendingPathComponent("partial.part"))
        let backupDir = root.appendingPathComponent(".backup-old", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try Data(repeating: 0x48, count: 256).write(to: backupDir.appendingPathComponent("old.bin"))

        let library = ModelLibrary(rootURL: root)
        let breakdown = try await library.storageBreakdown()
        #expect(breakdown.perModelBytes == [ModelStorageEntry(id: "modelA", bytes: Int64(4096 + manifestSize))])
        #expect(breakdown.installedBytes == Int64(4096 + manifestSize))
        #expect(breakdown.stagingBytes == 512)
        #expect(breakdown.tempBytes == 768)
        #expect(breakdown.totalBytes == breakdown.installedBytes + breakdown.tempBytes)
    }

    // MARK: Background records

    @Test("Background stores persist attempt fields with bounds")
    func backgroundRecordBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileModelBackgroundDownloadStore(fileURL: root.appendingPathComponent("bg.json"))
        let request = ModelBackgroundDownloadRequest(
            identifier: "transfer-1",
            url: URL(string: "https://models.example.test/bg.aimodel")!,
            destinationURL: root.appendingPathComponent("library/staged.aimodel"),
            headers: ["Authorization": "Bearer secret", "Accept": "application/octet-stream"]
        )
        let record = ModelBackgroundDownloadRecord(
            request: request,
            status: .failed,
            bytesDownloaded: 128,
            totalBytes: 1024,
            lastError: String(repeating: "e", count: 500),
            attempt: 3,
            resumedFromBytes: 64,
            deltaReusedBytes: 32
        )
        // Oversized resume blobs are dropped rather than persisted.
        var oversized = record
        oversized.resumeData = Data(repeating: 0x49, count: 2 * 1024 * 1024)
        try await store.save(oversized)
        let loaded = try #require(try await store.record(for: "transfer-1"))
        #expect(loaded.attempt == 3)
        #expect(loaded.resumedFromBytes == 64)
        #expect(loaded.deltaReusedBytes == 32)
        #expect(loaded.lastError?.count == 300)
        #expect(loaded.resumeData == nil)
        #expect(loaded.request.headers["Authorization"] == nil)
        #expect(loaded.request.headers["Accept"] == "application/octet-stream")
    }

    @Test("Legacy background records decode with default attempt fields")
    func legacyBackgroundRecordDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-bg-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("bg.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        [{"request":{"identifier":"legacy-1","url":"https://models.example.test/legacy.aimodel","destinationURL":"file:///tmp/staged.aimodel","headers":{}},"taskIdentifier":null,"encryptedResumeData":null,"status":"paused","bytesDownloaded":10,"totalBytes":100,"lastError":null}]
        """
        try Data(legacy.utf8).write(to: fileURL)
        let store = FileModelBackgroundDownloadStore(fileURL: fileURL)
        let loaded = try #require(try await store.record(for: "legacy-1"))
        #expect(loaded.attempt == 1)
        #expect(loaded.resumedFromBytes == nil)
        #expect(loaded.deltaReusedBytes == nil)
        #expect(loaded.status == .paused)
    }

    // MARK: Catalog family/benchmark carriage

    @Test("Hugging Face catalog carries family and never invents scores")
    func hfCatalogCarriesFamily() async throws {
        let payload = """
        {"id":"Qwen/Qwen3-0.6B","author":"Qwen","tags":[],"siblings":[{"rfilename":"model.safetensors","size":100}],"sha":"abc123","private":false}
        """
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: StubHTTPClient(payload: Data(payload.utf8)),
            tokenStore: nil
        )
        let model = try await catalog.inspect(repositoryID: "Qwen/Qwen3-0.6B")
        #expect(model.family == "Qwen")
        #expect(model.benchmarks.isEmpty)
    }

    @Test("Prep recipe errors are typed")
    func prepRecipeError() {
        let error = ArchonModelsError.prepRecipeUnavailable("gguf -> mlx (Klingon)")
        #expect(error.errorDescription?.contains("No preparation recipe") == true)
    }
}
