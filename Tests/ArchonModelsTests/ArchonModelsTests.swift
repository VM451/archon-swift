import CryptoKit
import Foundation
import Testing
@testable import ArchonModels
import ArchonCore

private struct ModelDownloadStubState: Sendable {
    let body: Data
    var statusCodes: [Int]
}

private final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var statesByPath: [String: ModelDownloadStubState] = [:]

    static func configure(body: Data, statusCodes: [Int] = [], for url: URL) {
        stateLock.lock()
        statesByPath[url.path] = ModelDownloadStubState(body: body, statusCodes: statusCodes)
        stateLock.unlock()
    }

    static func reset(for url: URL) {
        stateLock.lock()
        statesByPath.removeValue(forKey: url.path)
        stateLock.unlock()
    }

    private static func nextResponse(for url: URL?) -> (body: Data, statusCode: Int) {
        let path = url?.path ?? ""
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var state = statesByPath[path] else { return (Data(), 200) }
        let statusCode = state.statusCodes.isEmpty ? 200 : state.statusCodes.removeFirst()
        statesByPath[path] = state
        return (state.body, statusCode)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, statusCode) = Self.nextResponse(for: request.url)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct MockHTTPClient: ModelHTTPClient {
    let payload: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw ArchonModelsError.invalidResponse
        }
        return (payload, response)
    }
}

private actor RecordingModelHTTPClient: ModelHTTPClient {
    let payload: Data
    private var requestedURLs: [URL] = []

    init(payload: Data) {
        self.payload = payload
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url {
            requestedURLs.append(url)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw ArchonModelsError.invalidResponse
        }
        return (payload, response)
    }

    func lastRequestedURL() -> URL? {
        requestedURLs.last
    }
}

private actor OfficialHuggingFaceHTTPClient: ModelHTTPClient {
    let officialPayload: Data
    private var requestedURLs: [URL] = []

    init(officialPayload: Data) {
        self.officialPayload = officialPayload
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw ArchonModelsError.invalidResponse
        }
        requestedURLs.append(url)
        let author = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "author" })?.value
        return (author?.lowercased() == "qwen" ? officialPayload : Data("[]".utf8), response)
    }

    func requestedURLsSnapshot() -> [URL] {
        requestedURLs
    }
}

private actor PagingModelHTTPClient: ModelHTTPClient {
    let responses: [Data]
    let nextPageURL: URL
    private var responseIndex = 0
    private var requestedURLs: [URL] = []

    init(responses: [Data], nextPageURL: URL) {
        self.responses = responses
        self.nextPageURL = nextPageURL
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              !responses.isEmpty,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: responseIndex == 0
                    ? ["Link": "<\(nextPageURL.absoluteString)>; rel=\"next\""]
                    : nil
              ) else {
            throw ArchonModelsError.invalidResponse
        }
        requestedURLs.append(url)
        let data = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        return (data, response)
    }

    func requestedURL(at index: Int) -> URL? {
        requestedURLs.indices.contains(index) ? requestedURLs[index] : nil
    }
}

private actor ControlledModelByteTransfer {
    private let payload: [UInt8]
    private var continuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [URLRequest] = []

    init(payload: Data) {
        self.payload = Array(payload)
    }

    func stream(for request: URLRequest) -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<UInt8, Error>.makeStream()
        self.continuation = continuation
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()

        let start = request.value(forHTTPHeaderField: "Range")
            .flatMap { $0.split(separator: "=").last?.split(separator: "-").first }
            .flatMap { Int64($0) } ?? 0
        let remaining = max(Int64(payload.count) - start, 0)
        let end = max(Int64(payload.count) - 1, 0)
        let headers: [String: String]
        let statusCode: Int
        if start > 0 {
            statusCode = 206
            headers = [
                "Content-Length": String(remaining),
                "Content-Range": "bytes \(start)-\(end)/\(payload.count)"
            ]
        } else {
            statusCode = 200
            headers = ["Content-Length": String(payload.count)]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (stream, response)
    }

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func yield(_ bytes: [UInt8]) {
        for byte in bytes { continuation?.yield(byte) }
    }

    func finishCurrent() {
        continuation?.finish()
        continuation = nil
    }

    func lastRangeHeader() -> String? {
        requests.last?.value(forHTTPHeaderField: "Range")
    }
}

struct ArchonModelsTests {
    private let device = ArchonDeviceCapabilities(
        platform: .iOS,
        osVersion: ArchonOSVersion(major: 27),
        physicalMemoryBytes: 8_000_000_000,
        availableMemoryBytes: 6_000_000_000,
        processorCount: 6,
        deviceArchitecture: "arm64",
        supportsAppleFoundationModels: true,
        supportsCoreAI: true
    )

    @Test("Runtime capability negotiation rejects unsupported tool contracts")
    func rejectsUnsupportedRuntimeCapabilities() {
        let variant = ModelVariant(
            id: "text-only-coreai",
            name: "text-only.aimodel",
            modelID: "example/text-only",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            estimatedMemoryBytes: 100,
            capabilities: ArchonModelCapabilities(
                tasks: [.textGeneration],
                supportsStreaming: true,
                supportsToolCalling: false,
                supportsStructuredOutput: true
            )
        )

        let compatibility = ModelCompatibilityAnalyzer.analyze(
            variant: variant,
            device: device,
            requirements: ModelCapabilityRequirements(
                task: .textGeneration,
                requiresStreaming: true,
                requiresToolCalling: true
            )
        )

        #expect(compatibility.status == .unsupportedFormat)
        #expect(compatibility.canLoad == false)
    }

    @Test("Raw SafeTensors are conversion-required, never directly runnable")
    func refusesRawSafeTensors() {
        let variant = ModelVariant(
            id: "qwen-raw",
            name: "model.safetensors",
            modelID: "Qwen/Qwen3",
            source: .huggingFace,
            format: .safetensors,
            runtime: .unknown,
            sizeBytes: 100,
            estimatedMemoryBytes: 100
        )

        let result = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)

        #expect(result.status == .conversionRequired)
        #expect(result.canLoad == false)
    }

    @Test("A Core AI artifact within budget is compatible")
    func acceptsCompatibleCoreAIArtifact() {
        let variant = ModelVariant(
            id: "qwen-coreai",
            name: "qwen.aimodel",
            modelID: "Qwen/Qwen3",
            source: .archonRegistry,
            format: .aimodel,
            runtime: .coreAI,
            minimumOS: ArchonOSVersion(major: 27),
            sizeBytes: 100,
            estimatedMemoryBytes: 100
        )

        let result = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)

        #expect(result.status == .compatible)
        #expect(result.canLoad)
    }

    @Test("Peak model prediction includes runtime, context, and safety reserves")
    func predictsPeakModelMemory() throws {
        let variant = ModelVariant(
            id: "mlx-estimate",
            name: "estimate.mlx",
            modelID: "example/estimate",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            contextLength: 8_192,
            sizeBytes: 1_000_000_000
        )

        let estimate = try #require(ModelCompatibilityAnalyzer.estimatedPeakMemory(for: variant))
        #expect(estimate.artifactOrWeightsBytes == 1_150_000_000)
        #expect(estimate.runtimeOverheadBytes > 0)
        #expect(estimate.kvCacheBytes > 0)
        #expect(estimate.safetyMarginBytes >= 64 * 1_048_576)
        #expect(estimate.peakBytes > estimate.artifactOrWeightsBytes)
        #expect(estimate.isHeuristic)
    }

    @Test("Runnable local artifacts without a measurable size fail closed")
    func rejectsUnestimableLocalArtifact() {
        let variant = ModelVariant(
            id: "unknown-memory",
            name: "unknown-memory.mlx",
            modelID: "example/unknown-memory",
            source: .localImport,
            format: .mlx,
            runtime: .mlx
        )

        let result = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)

        #expect(result.status == .memoryEstimateUnavailable)
        #expect(!result.canLoad)
    }

    @Test("Model downloads fail before transfer when the device budget is exceeded")
    func rejectsDownloadBeforeTransferWhenMemoryIsInsufficient() async throws {
        let variant = ModelVariant(
            id: "oversized-download",
            name: "oversized.mlx",
            modelID: "example/oversized-download",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/oversized.mlx"),
            format: .mlx,
            runtime: .mlx,
            sizeBytes: Int64(device.recommendedModelMemoryBytes) + 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            byteStreamProvider: { _ in
                throw ArchonModelsError.invalidResponse
            }
        )

        do {
            _ = try await manager.download(
                ModelDownloadRequest(variant: variant, modelName: "Oversized"),
                into: ModelLibrary(rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("archon-memory-gated-download-\(UUID().uuidString)")),
                on: device
            )
            Issue.record("Expected the model download to be rejected before transfer.")
        } catch let error as ArchonModelsError {
            #expect(error == .incompatible(.insufficientMemory))
        } catch {
            Issue.record("Unexpected model download error: \(error)")
        }
    }

    @Test("Direct artifact formats cannot claim a different runtime")
    func rejectsMismatchedDirectArtifactRuntime() {
        let variant = ModelVariant(
            id: "mismatched-coreai",
            name: "model.aimodel",
            modelID: "example/mismatch",
            source: .localImport,
            format: .aimodel,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )

        let result = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)

        #expect(result.status == .unsupportedFormat)
        #expect(result.canLoad == false)

        let manifest = ArchonModelManifest(variant: variant, modelName: variant.name)
        let report = ModelManifestValidator.validate(manifest)
        #expect(report.errors.contains { $0.contains("must declare the coreAI runtime") })
    }

    @Test("Experimental Core AI exports remain visibly blocked until validation")
    func blocksExperimentalCoreAIExport() throws {
        let variant = ModelVariant(
            id: "experimental-coreai",
            name: "experimental.aimodel",
            modelID: "example/experimental",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            estimatedMemoryBytes: 100,
            isExperimental: true
        )

        let compatibility = ModelCompatibilityAnalyzer.analyze(variant: variant, device: device)
        #expect(compatibility.status == .experimental)
        #expect(compatibility.canLoad == false)
        #expect(ModelCompatibilityAnalyzer.recommendedVariant(
            for: ModelDescriptor(
                id: "example/experimental",
                name: "Experimental",
                publisher: "Example",
                source: .localImport,
                variants: [variant]
            ),
            device: device
        ) == nil)

        let manifest = ArchonModelManifest(variant: variant, modelName: "Experimental")
        let decoded = try JSONDecoder().decode(
            ArchonModelManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(decoded.isExperimental)
        #expect(ModelManifestValidator.validate(decoded).warnings.contains {
            $0.contains("Experimental")
        })
    }

    @Test("Thermal pressure blocks model loading with an explicit compatibility state")
    func blocksThermallyConstrainedModel() {
        let variant = ModelVariant(
            id: "mlx-hot",
            name: "model.mlx",
            modelID: "example/model",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100
        )
        let hotDevice = ArchonDeviceCapabilities(
            platform: .iOS,
            osVersion: ArchonOSVersion(major: 27),
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 6_000_000_000,
            processorCount: 6,
            deviceArchitecture: "arm64",
            supportsAppleFoundationModels: true,
            supportsCoreAI: true,
            thermalState: .serious
        )

        let result = ModelCompatibilityAnalyzer.analyze(variant: variant, device: hotDevice)

        #expect(result.status == .thermalConstrained)
        #expect(!result.canLoad)
    }

    @Test("Variant recommendation prefers the best fit, then the native runtime")
    func recommendsVariantDeterministically() {
        let smallerMLX = ModelVariant(
            id: "mlx-small",
            name: "small.mlx",
            modelID: "example/model",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            precision: "Q4",
            estimatedMemoryBytes: 500
        )
        let largerCoreAI = ModelVariant(
            id: "core-large",
            name: "large.aimodel",
            modelID: "example/model",
            source: .appleCoreAI,
            format: .aimodel,
            runtime: .coreAI,
            precision: "FP16",
            estimatedMemoryBytes: 1_000_000_000
        )
        let model = ModelDescriptor(
            id: "example/model",
            name: "Example",
            publisher: "Example",
            source: .archonRegistry,
            variants: [largerCoreAI, smallerMLX]
        )

        #expect(ModelCompatibilityAnalyzer.recommendedVariant(for: model, device: device)?.id == "mlx-small")
        #expect(ModelCompatibilityAnalyzer.quantizationAlternatives(for: model, device: device).map(\.id) == ["core-large", "mlx-small"])
    }

    @Test("Variant quality and speed metadata influence deterministic recommendations")
    func recommendsQualityWhenFitIsEqual() throws {
        let lowerQuality = ModelVariant(
            id: "lower-quality",
            name: "lower-quality.mlx",
            modelID: "example/quality",
            source: .localImport,
            format: .mlx,
            runtime: .mlx,
            estimatedMemoryBytes: 100,
            estimatedQualityScore: 0.4,
            estimatedTokensPerSecond: 80
        )
        let higherQuality = ModelVariant(
            id: "higher-quality",
            name: "higher-quality.aimodel",
            modelID: "example/quality",
            source: .appleCoreAI,
            format: .aimodel,
            runtime: .coreAI,
            estimatedMemoryBytes: 100,
            estimatedQualityScore: 0.9,
            estimatedTokensPerSecond: 40
        )
        let model = ModelDescriptor(
            id: "example/quality",
            name: "Quality",
            publisher: "Example",
            source: .archonRegistry,
            variants: [lowerQuality, higherQuality]
        )

        #expect(ModelCompatibilityAnalyzer.recommendedVariant(for: model, device: device)?.id == "higher-quality")

        let manifest = ArchonModelManifest(variant: higherQuality, modelName: "Quality")
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ArchonModelManifest.self, from: encoded)
        #expect(decoded.estimatedQualityScore == 0.9)
        #expect(decoded.estimatedTokensPerSecond == 40)
    }

    @Test("Manifest validation rejects invalid quality and speed estimates")
    func rejectsInvalidQualityAndSpeedMetadata() {
        let manifest = ArchonModelManifest(
            modelID: "example/invalid-metadata",
            modelName: "Invalid Metadata",
            runtime: .coreAI,
            format: .aimodel,
            estimatedQualityScore: 1.5,
            estimatedTokensPerSecond: -1
        )

        let report = ModelManifestValidator.validate(manifest)

        #expect(report.errors.contains { $0.contains("estimatedQualityScore") })
        #expect(report.errors.contains { $0.contains("estimatedTokensPerSecond") })
    }

    @Test("Manifest validation rejects raw formats before packaging")
    func rejectsRawManifest() {
        let manifest = ArchonModelManifest(
            modelID: "Qwen/Qwen3",
            modelName: "qwen.safetensors",
            runtime: .unknown,
            format: .safetensors
        )

        let report = ModelManifestValidator.validate(manifest)

        #expect(report.isValid == false)
        #expect(report.errors.contains { $0.contains("requires conversion") })
        #expect(report.errors.contains { $0.contains("runtime") })
    }

    @Test("Manifest validation checks a packaged artifact checksum and size")
    func validatesPackagedArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.aimodel")
        let data = Data("model".utf8)
        try data.write(to: artifact)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = ArchonModelManifest(
            modelID: "Qwen/Qwen3",
            modelName: "Qwen3",
            runtime: .coreAI,
            format: .aimodel,
            checksum: checksum,
            modelSizeBytes: Int64(data.count)
        )

        let report = ModelManifestValidator.validate(manifest, artifactAt: artifact)

        #expect(report.isValid)
        #expect(report.errors.isEmpty)
    }

    @Test("Single-file artifacts cannot silently omit declared resources")
    func rejectsResourcesOnSingleFileArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-resource-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.mlx")
        try Data("model".utf8).write(to: artifact)
        let manifest = ArchonModelManifest(
            modelID: "mlx/example",
            modelName: "Example MLX",
            runtime: .mlx,
            format: .mlx,
            modelResources: [ModelResource(name: "weights", relativePath: "weights.bin")]
        )

        let report = ModelManifestValidator.validate(manifest, artifactAt: artifact)

        #expect(report.isValid == false)
        #expect(report.errors.contains { $0.contains("require a directory artifact") })
    }

    @Test("Direct imports reject artifacts that fail manifest integrity checks")
    func rejectsIntegrityMismatchDuringImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.aimodel")
        try Data("model".utf8).write(to: artifact)
        let manifest = ArchonModelManifest(
            modelID: "Qwen/Qwen3",
            modelName: "Qwen3",
            runtime: .coreAI,
            format: .aimodel,
            modelSizeBytes: 999
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))

        do {
            _ = try await library.importArtifact(at: artifact, manifest: manifest)
            Issue.record("Import unexpectedly accepted a mismatched artifact.")
        } catch let error as ArchonModelsError {
            #expect(error == .invalidManifest(["Artifact size mismatch: expected 999, received 5."]))
        } catch {
            Issue.record("Import failed with an unexpected error: \(error)")
        }
    }

    @Test("Hugging Face metadata maps licenses and artifact formats without live networking")
    func parsesHuggingFaceMetadata() async throws {
        let payload = Data(#"""
        [{
          "id": "Qwen/Qwen3",
          "author": "Qwen",
          "pipeline_tag": "text-generation",
          "tags": ["3b"],
          "architectures": ["Qwen3ForCausalLM"],
          "gated": false,
          "private": false,
          "sha": "immutable-revision",
          "cardData": {"license": "apache-2.0", "license_link": "https://example.com/license", "language": ["en", "zh"], "thumbnail": "https://cdn.example.test/qwen.png"},
          "siblings": [
            {"rfilename": "qwen.safetensors", "size": 100},
            {"rfilename": "pytorch_model.bin", "size": 110},
            {"rfilename": "qwen.aimodel", "size": 90}
          ]
        }]
        """#.utf8)
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: MockHTTPClient(payload: payload),
            tokenStore: nil
        )

        let models = try await catalog.search(ModelSearchRequest(query: "Qwen"))
        let model = try #require(models.first)

        #expect(model.license?.identifier == "apache-2.0")
        #expect(model.licenseURL == URL(string: "https://example.com/license"))
        #expect(model.logoURL == URL(string: "https://cdn.example.test/qwen.png"))
        #expect(model.supportedLanguages == ["en", "zh"])
        #expect(model.variants.map(\.format) == [.safetensors, .transformers, .aimodel])
        #expect(model.variants.last?.runtime == .coreAI)
        #expect(try await catalog.search(ModelSearchRequest(query: "Qwen", task: .vision)).isEmpty)

        let compatibleWithoutDetails = try await catalog.search(ModelSearchRequest(
            query: "Qwen",
            compatibleOnly: true,
            device: device,
            includeVariants: false
        ))
        #expect(compatibleWithoutDetails.count == 1)
        #expect(compatibleWithoutDetails.first?.variants.isEmpty == true)

        let recorder = RecordingModelHTTPClient(payload: payload)
        let compactCatalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: recorder,
            tokenStore: nil
        )
        _ = try await compactCatalog.search(ModelSearchRequest(
            query: "Qwen",
            compatibleOnly: true,
            device: device,
            includeVariants: false
        ))
        let requestURL = try #require(await recorder.lastRequestedURL())
        let queryItems = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(queryItems.first(where: { $0.name == "full" })?.value == "true")
    }

    @Test("Catalog pages honor offsets and report remaining results")
    func paginatesStaticCatalog() async throws {
        let catalog = StaticModelCatalog(models: (0..<3).map { index in
            ModelDescriptor(
                id: "model-\(index)",
                name: "Model \(index)",
                publisher: "Test",
                source: .developerRegistry
            )
        })

        let firstPage = try await catalog.searchPage(ModelSearchRequest(query: "", offset: -1, limit: 2))
        #expect(firstPage.models.map(\.id) == ["model-0", "model-1"])
        #expect(firstPage.hasMore)
        #expect(firstPage.nextContinuationToken == nil)

        let secondPage = try await catalog.searchPage(ModelSearchRequest(query: "", offset: 2, limit: 2))
        #expect(secondPage.models.map(\.id) == ["model-2"])
        #expect(!secondPage.hasMore)
    }

    @Test("MLX catalog boundary hides non-MLX model variants")
    func mlxCatalogOnlyReturnsMLXVariants() async throws {
        let mlxVariant = ModelVariant(
            id: "qwen-mlx",
            name: "Qwen MLX",
            modelID: "mlx-community/Qwen3-8B-4bit",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let coreAIVariant = ModelVariant(
            id: "qwen-coreai",
            name: "Qwen Core AI",
            modelID: "Qwen/Qwen3",
            source: .appleCoreAI,
            format: .aimodel,
            runtime: .coreAI
        )
        let catalog = MLXModelCatalog(provider: StaticModelCatalog(models: [
            ModelDescriptor(
                id: "mixed-model",
                name: "Mixed Model",
                publisher: "Test",
                source: .developerRegistry,
                variants: [mlxVariant, coreAIVariant]
            ),
            ModelDescriptor(
                id: "coreai-only",
                name: "Core AI Only",
                publisher: "Test",
                source: .appleCoreAI,
                variants: [coreAIVariant]
            )
        ]))

        let page = try await catalog.searchPage(ModelSearchRequest(query: "", limit: 1))

        #expect(page.models.map(\.id) == ["mixed-model"])
        #expect(page.models.first?.variants.map(\.runtime) == [.mlx])
        #expect(page.models.first?.variants.map(\.format) == [.mlx])
        let continuation = try #require(page.nextContinuationToken)
        let nextPage = try await catalog.searchPage(ModelSearchRequest(
            query: "",
            continuationToken: continuation,
            limit: 1
        ))
        #expect(nextPage.models.isEmpty)
        #expect(!nextPage.hasMore)
        #expect(try await catalog.search(ModelSearchRequest(query: "", runtime: .coreAI)).isEmpty)
    }

    @Test("Official catalog excludes community MLX conversions")
    func officialCatalogOnlyReturnsFirstPartyNamespaces() async throws {
        let officialVariant = ModelVariant(
            id: "qwen-official-mlx",
            name: "Qwen official MLX",
            modelID: "Qwen/Qwen3-0.6B",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let communityVariant = ModelVariant(
            id: "qwen-community-mlx",
            name: "Qwen community conversion",
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let catalog = OfficialModelCatalog(provider: StaticModelCatalog(models: [
            ModelDescriptor(
                id: "mlx-community/Qwen3-0.6B-4bit",
                name: "Qwen community conversion",
                publisher: "mlx-community",
                source: .huggingFace,
                variants: [communityVariant]
            ),
            ModelDescriptor(
                id: "Qwen/Qwen3-0.6B",
                name: "Qwen official MLX",
                publisher: "Qwen",
                source: .huggingFace,
                variants: [officialVariant]
            ),
            ModelDescriptor(
                id: "Qwen/Qwen3-mixed",
                name: "Qwen with community variant",
                publisher: "Qwen",
                source: .huggingFace,
                variants: [communityVariant]
            )
        ]))

        let models = try await catalog.search(ModelSearchRequest(query: "", limit: 10))

        #expect(models.map(\.id) == ["Qwen/Qwen3-0.6B"])
        #expect(models.first?.variants.map(\.modelID) == ["Qwen/Qwen3-0.6B"])
    }

    @Test("Official catalog keeps pagination while skipping non-official pages")
    func officialCatalogSkipsCommunityPageWithoutStarvingResults() async throws {
        let communityVariant = ModelVariant(
            id: "community-mlx",
            name: "Community MLX",
            modelID: "mlx-community/Community-Model",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let officialVariant = ModelVariant(
            id: "mistral-mlx",
            name: "Mistral MLX",
            modelID: "mistralai/Mistral-7B",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let catalog = OfficialModelCatalog(provider: StaticModelCatalog(models: [
            ModelDescriptor(
                id: "mlx-community/Community-Model",
                name: "Community MLX",
                publisher: "mlx-community",
                source: .huggingFace,
                variants: [communityVariant]
            ),
            ModelDescriptor(
                id: "mistralai/Mistral-7B",
                name: "Mistral MLX",
                publisher: "mistralai",
                source: .huggingFace,
                variants: [officialVariant]
            )
        ]))

        let page = try await catalog.searchPage(ModelSearchRequest(query: "", limit: 1))

        #expect(page.models.map(\.id) == ["mistralai/Mistral-7B"])
        #expect(!page.hasMore)
    }

    @Test("Official Hugging Face discovery scopes requests to first-party namespaces")
    func officialCatalogScopesHuggingFaceRequests() async throws {
        let payload = Data(#"""
        [{
          "id": "Qwen/Qwen3-0.6B-MLX-4bit",
          "author": "Qwen",
          "pipeline_tag": "text-generation",
          "tags": ["mlx", "0.6b"],
          "siblings": [
            {"rfilename": "model.safetensors", "size": 100},
            {"rfilename": "config.json", "size": 20},
            {"rfilename": "tokenizer.json", "size": 30}
          ]
        }]
        """#.utf8)
        let session = OfficialHuggingFaceHTTPClient(officialPayload: payload)
        let catalog = OfficialModelCatalog(provider: HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: session,
            tokenStore: nil
        ))

        let models = try await catalog.search(ModelSearchRequest(query: "Qwen", limit: 1))
        #expect(models.map(\.id) == ["Qwen/Qwen3-0.6B-MLX-4bit"])

        let urls = await session.requestedURLsSnapshot()
        let authors = urls.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "author" })?.value
        }
        #expect(authors.contains("Qwen"))
        #expect(authors.allSatisfy {
            OfficialModelCatalogPolicy.defaultHuggingFaceOrganizations.contains($0.lowercased())
        })
    }

    @Test("Wrapping an official catalog twice does not duplicate its provider boundary")
    func officialCatalogWrappingIsIdempotent() async throws {
        let provider = StaticModelCatalog(models: [])
        let first = OfficialModelCatalog(provider: provider)
        let second = OfficialModelCatalog(provider: first)

        #expect(second.id == first.id)
        #expect(second.policy == first.policy)
        #expect(try await second.search(ModelSearchRequest(query: "")).isEmpty)
    }

    @Test("Composite catalog pagination keeps each provider's cursor")
    func paginatesCompositeCatalog() async throws {
        func descriptor(_ id: String) -> ModelDescriptor {
            ModelDescriptor(
                id: id,
                name: id,
                publisher: "Test",
                source: .developerRegistry
            )
        }

        let catalog = CompositeModelCatalog(providers: [
            StaticModelCatalog(models: [descriptor("first-0"), descriptor("first-1"), descriptor("first-2")]),
            StaticModelCatalog(models: [descriptor("second-0")])
        ])

        let firstPage = try await catalog.searchPage(ModelSearchRequest(query: "", limit: 2))
        let token = try #require(firstPage.nextContinuationToken)
        #expect(firstPage.models.map(\.id) == ["first-0", "first-1"])
        #expect(firstPage.hasMore)

        let secondPage = try await catalog.searchPage(ModelSearchRequest(
            query: "",
            continuationToken: token,
            limit: 2
        ))
        #expect(secondPage.models.map(\.id) == ["first-2", "second-0"])
        #expect(!secondPage.hasMore)
    }

    @Test("Hugging Face pages follow the provider cursor instead of restarting discovery")
    func followsHuggingFaceContinuationToken() async throws {
        let firstPayload = Data(#"""
        [{"id":"mlx-community/First","pipeline_tag":"text-generation","tags":["mlx"]}]
        """#.utf8)
        let secondPayload = Data(#"""
        [{"id":"mlx-community/Second","pipeline_tag":"text-generation","tags":["mlx"]}]
        """#.utf8)
        let nextURL = URL(string: "https://example.com/api/models?filter=mlx&cursor=next")!
        let session = PagingModelHTTPClient(
            responses: [firstPayload, secondPayload],
            nextPageURL: nextURL
        )
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: session,
            tokenStore: nil
        )

        let firstPage = try await catalog.searchPage(ModelSearchRequest(query: "Qwen", runtime: .mlx, limit: 1))
        let token = try #require(firstPage.nextContinuationToken)
        #expect(firstPage.models.map(\.id) == ["mlx-community/First"])
        #expect(firstPage.hasMore)

        let secondPage = try await catalog.searchPage(ModelSearchRequest(
            query: "Qwen",
            runtime: .mlx,
            continuationToken: token,
            limit: 1
        ))
        #expect(secondPage.models.map(\.id) == ["mlx-community/Second"])
        #expect(!secondPage.hasMore)
        #expect(await session.requestedURL(at: 1) == nextURL)
    }

    @Test("Hugging Face MLX search finds current tagged packages instead of only popular raw checkpoints")
    func searchesRunnableMLXPackages() async throws {
        let payload = Data(#"""
        [{
          "id": "lmstudio-community/Qwen3.8-27B-MLX-4bit",
          "author": "lmstudio-community",
          "pipeline_tag": "image-text-to-text",
          "library_name": "transformers",
          "tags": ["transformers", "safetensors", "qwen3_5", "image-text-to-text", "mlx", "base_model:Qwen/Qwen3.8-27B", "4-bit"],
          "gated": false,
          "private": false,
          "sha": "current-mlx-revision",
          "siblings": [
            {"rfilename": "model.safetensors", "size": 100},
            {"rfilename": "config.json", "size": 20},
            {"rfilename": "tokenizer.json", "size": 30}
          ]
        }]
        """#.utf8)
        let recorder = RecordingModelHTTPClient(payload: payload)
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: recorder,
            tokenStore: nil
        )

        let models = try await catalog.search(ModelSearchRequest(query: "Qwen", runtime: .mlx))
        let model = try #require(models.first)
        let variant = try #require(model.variants.first)
        let requestURL = try #require(await recorder.lastRequestedURL())
        let queryItems = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(model.family == "Qwen")
        #expect(model.parameterCount == 27_000_000_000)
        #expect(model.tasks.contains(.textGeneration))
        #expect(model.tasks.contains(.vision))
        #expect(variant.format == .mlx)
        #expect(variant.capabilities.tasks.contains(.textGeneration))
        #expect(queryItems.first(where: { $0.name == "filter" })?.value == "mlx")
    }

    @Test("Compatible Hugging Face search continues past raw repositories")
    func compatibleSearchDoesNotStopAtRawRepository() async throws {
        let payload = Data(#"""
        [
          {
            "id": "Qwen/Qwen3-8B",
            "pipeline_tag": "text-generation",
            "tags": ["transformers", "safetensors", "8b"],
            "siblings": [{"rfilename": "model.safetensors", "size": 100}]
          },
          {
            "id": "mlx-community/Qwen3-8B-4bit",
            "pipeline_tag": "text-generation",
            "library_name": "mlx",
            "tags": ["mlx", "text-generation", "8b"],
            "siblings": [
              {"rfilename": "model.safetensors", "size": 100},
              {"rfilename": "config.json", "size": 20},
              {"rfilename": "tokenizer.json", "size": 30}
            ]
          }
        ]
        """#.utf8)
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: MockHTTPClient(payload: payload),
            tokenStore: nil
        )

        let models = try await catalog.search(ModelSearchRequest(
            query: "Qwen",
            compatibleOnly: true,
            device: device,
            limit: 1
        ))

        #expect(models.count == 1)
        #expect(models.first?.id == "mlx-community/Qwen3-8B-4bit")
        #expect(models.first?.variants.first?.format == .mlx)
        #expect(models.first?.logoURL == URL(string: "https://example.com/avatars/mlx-community?s=96"))
    }

    @Test("Hugging Face inspection rejects unsafe repository paths before requesting them")
    func rejectsUnsafeHuggingFaceRepositoryIDs() async throws {
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: MockHTTPClient(payload: Data("[]".utf8)),
            tokenStore: nil
        )

        for repositoryID in ["org/model/extra", "org/../model", "org/model?revision=main", "org/model\\name"] {
            await #expect(throws: ArchonModelsError.invalidModelIdentifier(repositoryID)) {
                _ = try await catalog.inspect(repositoryID: repositoryID)
            }
        }
    }

    @Test("Model license policy separates allowed, confirmation, and denied licenses")
    func evaluatesLicensePolicy() {
        let policy = ModelLicensePolicy(
            allowedIdentifiers: ["Apache-2.0", "MIT"],
            confirmationIdentifiers: ["custom-license"],
            unknownBehavior: .denied
        )

        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "apache-2.0")) == .allowed)
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "custom-license")) == .confirmationRequired)
        #expect(policy.decision(for: ModelLicenseMetadata(identifier: "GPL-3.0")) == .denied)
        #expect(policy.decision(for: nil) == .denied)
    }

    @Test("Download manager enforces an injected license policy before transfer")
    func enforcesLicensePolicyBeforeTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-license-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = ModelVariant(
            id: "license-policy-model",
            name: "model.aimodel",
            modelID: "example/license-policy",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1
        )
        let library = ModelLibrary(rootURL: root)
        let manager = ModelDownloadManager(
            session: URLSession.shared,
            tokenStore: nil,
            licensePolicy: ModelLicensePolicy(unknownBehavior: .denied)
        )
        let events = try await manager.download(
            ModelDownloadRequest(
                variant: variant,
                modelName: "License Policy",
                license: ModelLicenseMetadata(identifier: "unknown-license")
            ),
            into: library
        )

        do {
            for try await _ in events {}
            Issue.record("Expected the license policy to reject the download.")
        } catch let error as ArchonModelsError {
            #expect(error == .licenseDenied("unknown-license"))
        }
    }

    @Test("Direct URL catalog preserves source metadata and conversion status")
    func discoversDirectURLModel() async throws {
        let catalog = DirectURLModelCatalog(
            url: URL(string: "https://models.example.test/model.gguf")!,
            modelID: "example/model",
            modelName: "Example GGUF",
            format: .gguf,
            runtime: .unknown
        )

        let models = try await catalog.search(ModelSearchRequest(query: "example"))
        let variant = try #require(models.first?.variants.first)

        #expect(variant.source == .directURL)
        #expect(variant.downloadURL?.scheme == "https")
        #expect(ModelCompatibilityAnalyzer.analyze(variant: variant, device: device).status == .conversionRequired)
    }

    @Test("Remote catalogs decode registry responses and preserve catalog roles")
    func decodesRemoteCatalogs() async throws {
        let descriptor = ModelDescriptor(
            id: "apple/example",
            name: "Example Apple Model",
            publisher: "Example",
            source: .appleCoreAI,
            variants: [ModelVariant(
                id: "apple/example#coreai",
                name: "Example",
                modelID: "apple/example",
                source: .appleCoreAI,
                format: .aimodel,
                runtime: .coreAI
            )]
        )
        let payload = try JSONEncoder().encode([descriptor])
        let endpoint = URL(string: "https://registry.example.test/models?channel=stable")!

        let remote = RemoteModelCatalog(
            id: "developer-registry",
            endpoint: endpoint,
            session: MockHTTPClient(payload: payload)
        )
        let remoteModels = try await remote.search(ModelSearchRequest(query: "example"))
        #expect(remote.id == "developer-registry")
        #expect(remoteModels == [descriptor])

        let appleCatalog = AppleCoreAIModelCatalog(
            endpoint: endpoint,
            session: MockHTTPClient(payload: payload)
        )
        let archonCatalog = ArchonCompatibleModelCatalog(
            endpoint: endpoint,
            session: MockHTTPClient(payload: payload)
        )
        #expect(appleCatalog.id == "apple-coreai")
        #expect(archonCatalog.id == "archon-registry")
        #expect(try await appleCatalog.search(ModelSearchRequest(query: "example")) == [descriptor])
        #expect(try await archonCatalog.search(ModelSearchRequest(query: "example")) == [descriptor])
    }

    @Test("Artifact inspector detects a runnable Core AI file and imports it without a manifest")
    func importsDetectedCoreAIArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-detected-aimodel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("example.aimodel")
        try Data("core-ai-model".utf8).write(to: artifact)

        let inspection = try ModelArtifactInspector.inspect(at: artifact)
        #expect(inspection.format == .aimodel)
        #expect(inspection.runtime == .coreAI)
        #expect(inspection.isRunnable)
        #expect(inspection.checksum?.count == 64)

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: artifact)
        #expect(installed.manifest.format == .aimodel)
        #expect(installed.manifest.supportedDeviceArchitectures == ["arm64"])
        #expect(try await library.contains(modelID: "local/example"))

        try await library.delete(modelID: "local/example")
        #expect(try await library.contains(modelID: "local/example") == false)
    }

    @Test("Embedded experimental manifests stay blocked after library import")
    func importsExperimentalManifestWithoutMakingItLoadable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-experimental-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("experimental.aimodel", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("experimental-core-ai".utf8).write(to: artifact.appendingPathComponent("weights.bin"))

        let manifest = ArchonModelManifest(
            modelID: "example/experimental",
            modelName: "Experimental",
            sourceRepository: "example/experimental",
            runtime: .coreAI,
            format: .coreAIBundle,
            supportedDeviceArchitectures: ["arm64"],
            platforms: [.iOS],
            isExperimental: true
        )
        try JSONEncoder().encode(manifest).write(
            to: artifact.appendingPathComponent(ArchonModelManifest.filename),
            options: .atomic
        )

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: artifact)
        #expect(installed.manifest.isExperimental)
        #expect(try await library.installedModels().first?.manifest.isExperimental == true)

        do {
            try await ModelLoadManager().load(installed, on: device)
            Issue.record("Experimental model unexpectedly loaded.")
        } catch let error as ArchonModelsError {
            #expect(error == .incompatible(.experimental))
        }
    }

    @Test("Artifact inspector detects MLX resources while preserving model architecture separately")
    func importsDetectedMLXDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-detected-mlx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("example", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(#"{"architectures":["ExampleForCausalLM"],"quantization":{"bits":4,"group_size":64}}"#.utf8)
            .write(to: artifact.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("model.safetensors"))
        try Data("tokenizer".utf8).write(to: artifact.appendingPathComponent("tokenizer.json"))

        let inspection = try ModelArtifactInspector.inspect(at: artifact)
        #expect(inspection.format == .mlx)
        #expect(inspection.runtime == .mlx)
        #expect(inspection.modelArchitecture == "ExampleForCausalLM")
        #expect(inspection.supportedDeviceArchitectures == ["arm64"])
        #expect(inspection.tokenizerResources.map(\.relativePath) == ["tokenizer.json"])

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: artifact)
        #expect(installed.manifest.architecture == "ExampleForCausalLM")
        #expect(installed.manifest.supportedDeviceArchitectures == ["arm64"])
        #expect(installed.manifest.modelResources.contains { $0.relativePath == "config.json" })
    }

    @Test("Generic Transformers directories remain conversion-required")
    func detectsRawTransformersDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-detected-transformers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("example", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(#"{"architectures":["ExampleForCausalLM"]}"#.utf8)
            .write(to: artifact.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("model.safetensors"))
        try Data("tokenizer".utf8).write(to: artifact.appendingPathComponent("tokenizer.json"))

        let inspection = try ModelArtifactInspector.inspect(at: artifact)
        #expect(inspection.format == .transformers)
        #expect(inspection.runtime == .unknown)
        #expect(inspection.requiresConversion)
        #expect(inspection.modelArchitecture == "ExampleForCausalLM")
    }

    @Test("Raw local files are identified but never imported as runnable models")
    func rejectsManifestFreeRawImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-detected-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("example.gguf")
        try Data("raw-weights".utf8).write(to: artifact)
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))

        do {
            _ = try await library.importArtifact(at: artifact)
            Issue.record("Raw GGUF unexpectedly imported as runnable.")
        } catch let error as ArchonModelsError {
            #expect(error.localizedDescription.contains("requires conversion"))
        }
    }

    @Test("Directory aggregate size is checked in addition to per-resource integrity")
    func rejectsDirectoryAggregateSizeMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-directory-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("weights.bin"))
        let manifest = ArchonModelManifest(
            modelID: "mlx/example",
            modelName: "Example",
            runtime: .mlx,
            format: .mlx,
            modelSizeBytes: 1
        )

        let report = ModelManifestValidator.validate(manifest, artifactAt: artifact)
        #expect(report.isValid == false)
        #expect(report.errors.contains { $0.contains("Directory artifact size mismatch") })
    }

    @Test("Local catalog discovers explicit Archon model packages")
    func discoversLocalModelPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-local-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = ArchonModelManifest(
            modelID: "local/example",
            modelName: "Local Example",
            runtime: .mlx,
            format: .mlx,
            architecture: "arm64"
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(ArchonModelManifest.filename))

        let models = try await LocalModelCatalog(locations: [root]).search(ModelSearchRequest(query: "Local Example"))
        let model = try #require(models.first)

        #expect(model.source == .localImport)
        #expect(model.sourceURL == root)
        #expect(model.variants.first?.downloadURL == nil)
    }

    @Test("Hugging Face MLX repositories expose a runnable multi-file package")
    func discoversMLXPackageResources() async throws {
        let payload = Data(#"""
        {
          "id": "mlx-community/Example",
          "author": "mlx-community",
          "pipeline_tag": "text-generation",
          "tags": ["mlx", "3b"],
          "architectures": ["ExampleForCausalLM"],
          "sha": "mlx-revision",
          "siblings": [
            {"rfilename": "model.safetensors", "size": 100, "lfs": {"sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 100}},
            {"rfilename": "config.json", "size": 40},
            {"rfilename": "tokenizer.json", "size": 60},
            {"rfilename": "README.md", "size": 10}
          ]
        }
        """#.utf8)
        let catalog = HuggingFaceCatalog(
            baseURL: URL(string: "https://example.com")!,
            session: MockHTTPClient(payload: payload),
            tokenStore: nil
        )

        let model = try #require(try await catalog.search(ModelSearchRequest(query: "mlx-community/Example")).first)
        let variant = try #require(model.variants.first(where: { $0.format == .mlx }))

        #expect(variant.runtime == .mlx)
        #expect(variant.resources.map(\.relativePath) == ["model.safetensors", "config.json", "tokenizer.json"])
        #expect(variant.sizeBytes == 200)
        #expect(variant.resources.first?.sha256?.count == 64)
    }

    @Test("Model download emits verification and ready states before completing")
    func downloadsAndInstallsArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = Data("downloaded-model".utf8)
        let downloadURL = URL(string: "https://models.example.test/model.aimodel")!
        ModelDownloadURLProtocol.configure(body: body, for: downloadURL)
        defer {
            ModelDownloadURLProtocol.reset(for: downloadURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let checksum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let variant = ModelVariant(
            id: "downloaded-model",
            name: "model.aimodel",
            modelID: "example/model",
            source: .directURL,
            downloadURL: downloadURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(body.count),
            sha256: checksum
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(session: session, tokenStore: nil)
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Example"),
            into: library
        )

        var states: [ModelDownloadState] = []
        for try await event in events {
            states.append(event.state)
        }

        #expect(states.contains { if case .verifying = $0 { true } else { false } })
        #expect(states.contains { if case .installing = $0 { true } else { false } })
        #expect(states.contains { if case .ready = $0 { true } else { false } })
        #expect(try await library.contains(modelID: "example/model"))
    }

    @Test("Model downloads pause and resume from the staged byte range")
    func pausesAndResumesDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-pause-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x41, count: 128 * 1024)
        let transfer = ControlledModelByteTransfer(payload: payload)
        let variant = ModelVariant(
            id: "pause-resume-model",
            name: "model.aimodel",
            modelID: "example/pause-resume",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/pause-resume.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(payload.count)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: { request in await transfer.stream(for: request) }
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Pause Resume"),
            into: library
        )

        var sawPaused = false
        for try await event in events {
            switch event.state {
            case .resolving:
                await transfer.waitForRequest()
                await transfer.yield(Array(payload.prefix(65_536)))
            case .downloading:
                if !sawPaused {
                    await manager.pause(variantID: variant.id)
                    await transfer.finishCurrent()
                }
            case .paused:
                sawPaused = true
            default:
                break
            }
        }
        #expect(sawPaused)

        let resumedEvents = try await manager.resume(variantID: variant.id, into: library)
        await transfer.waitForRequest()
        #expect(await transfer.lastRangeHeader() == "bytes=65536-")
        await transfer.yield(Array(payload.dropFirst(65_536)))
        await transfer.finishCurrent()

        var sawReady = false
        for try await event in resumedEvents {
            if case .ready = event.state { sawReady = true }
        }
        #expect(sawReady)
        #expect(try await library.contains(modelID: variant.modelID))
    }

    @Test("Model download cancellation emits cancellation and removes its staging artifact")
    func cancelsDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-download-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x42, count: 64 * 1024)
        let transfer = ControlledModelByteTransfer(payload: payload)
        let variant = ModelVariant(
            id: "cancelled-model",
            name: "model.aimodel",
            modelID: "example/cancelled",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/cancelled.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(payload.count)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: { request in await transfer.stream(for: request) }
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Cancelled"),
            into: library
        )
        await transfer.waitForRequest()
        await manager.cancel(variantID: variant.id)
        await transfer.finishCurrent()

        var sawCancelled = false
        do {
            for try await event in events {
                if case .cancelled = event.state { sawCancelled = true }
            }
            Issue.record("Expected cancellation to finish the download stream with an error.")
        } catch let error as ArchonModelsError {
            #expect(error == .cancelled)
        }
        #expect(sawCancelled)
        #expect(await manager.isDownloading(variantID: variant.id) == false)
        #expect(try await library.contains(modelID: variant.modelID) == false)
        #expect(try await library.diskUsageBytes() == 0)
    }

    @Test("Cancelling an event-stream consumer cancels the model download")
    func cancelsDownloadWhenEventConsumerStops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-download-stream-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = ControlledModelByteTransfer(payload: Data(repeating: 0x43, count: 64 * 1024))
        let variant = ModelVariant(
            id: "stream-cancelled-model",
            name: "model.aimodel",
            modelID: "example/stream-cancelled",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/stream-cancelled.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 64 * 1024
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0),
            byteStreamProvider: { request in await transfer.stream(for: request) }
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Stream Cancelled"),
            into: library
        )
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch {
                // Cancellation is asserted through the manager state below.
            }
        }

        await transfer.waitForRequest()
        consumer.cancel()
        _ = await consumer.result
        try await Task.sleep(for: .milliseconds(50))

        #expect(await manager.isDownloading(variantID: variant.id) == false)
        #expect(try await library.contains(modelID: variant.modelID) == false)
        await transfer.finishCurrent()
    }

    @Test("Cancelling a background event consumer detaches only that observer")
    func cancelsBackgroundEventConsumer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-event-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "background-event-cancel"
        let request = ModelBackgroundDownloadRequest(
            identifier: identifier,
            url: URL(string: "https://models.example.test/model.aimodel")!,
            destinationURL: root.appendingPathComponent("model.aimodel")
        )
        let store = InMemoryModelBackgroundDownloadStore()
        try await store.save(ModelBackgroundDownloadRecord(
            request: request,
            status: .downloading,
            bytesDownloaded: 128,
            totalBytes: 256
        ))
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-event-cancel.\(UUID().uuidString)",
            store: store,
            destinationRootURL: root
        )

        let events = try await coordinator.events(for: identifier)
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch {
                Issue.record("Unexpected background event stream failure: \(error)")
            }
        }
        consumer.cancel()
        _ = await consumer.result

        let replacementEvents = try await coordinator.events(for: identifier)
        var iterator = replacementEvents.makeAsyncIterator()
        let replacementEvent = try await iterator.next()
        #expect(replacementEvent?.state == .downloading(bytesDownloaded: 128, totalBytes: 256))
    }

    @Test("Cancelling an orphaned background record finishes its observer")
    func cancelsOrphanedBackgroundRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-orphan-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identifier = "orphaned-background"
        let destination = root.appendingPathComponent("model.part")
        try Data("partial".utf8).write(to: destination)
        let request = ModelBackgroundDownloadRequest(
            identifier: identifier,
            url: URL(string: "https://models.example.test/model.aimodel")!,
            destinationURL: destination
        )
        let store = InMemoryModelBackgroundDownloadStore()
        try await store.save(ModelBackgroundDownloadRecord(request: request, status: .downloading))
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-orphan-cancel.\(UUID().uuidString)",
            store: store,
            destinationRootURL: root
        )
        let events = try await coordinator.events(for: identifier)
        let consumer = Task {
            var states: [ModelBackgroundTransferState] = []
            do {
                for try await event in events {
                    states.append(event.state)
                }
            } catch {
                Issue.record("Unexpected orphaned background event failure: \(error)")
            }
            return states
        }

        try await coordinator.cancel(identifier: identifier)
        let states = await consumer.value
        #expect(states.contains(.cancelled))
        #expect(try await coordinator.record(for: identifier)?.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Background cancellation wins over a late completion callback")
    func backgroundCancellationWinsOverLateCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-late-completion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "background-late-completion"
        let destination = root.appendingPathComponent("model.part")
        let request = ModelBackgroundDownloadRequest(
            identifier: identifier,
            url: URL(string: "https://models.example.test/model.aimodel")!,
            destinationURL: destination
        )
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-late-completion.\(UUID().uuidString)",
            destinationRootURL: root
        )
        _ = try await coordinator.start(request)
        let taskIdentifier = try #require(try await coordinator.record(for: identifier)?.taskIdentifier)

        try await coordinator.cancel(identifier: identifier)
        // Exercise the callback ordering that can occur when cancellation and
        // didFinishDownloadingTo are delivered almost simultaneously.
        await coordinator.receiveFinished(taskIdentifier: taskIdentifier, destinationURL: destination, errorMessage: nil)

        #expect(try await coordinator.record(for: identifier)?.status == .cancelled)
        #expect(await coordinator.isActive(identifier: identifier) == false)
    }

    @Test("Reconnect marks missing active background tasks resumable")
    func reconnectRecoversMissingBackgroundTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-reconnect-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "background-reconnect-missing"
        let request = ModelBackgroundDownloadRequest(
            identifier: identifier,
            url: URL(string: "https://models.example.test/model.aimodel")!,
            destinationURL: root.appendingPathComponent("model.part")
        )
        let store = InMemoryModelBackgroundDownloadStore()
        try await store.save(ModelBackgroundDownloadRecord(
            request: request,
            taskIdentifier: 42,
            resumeData: Data("stale-resume-data".utf8),
            status: .downloading,
            bytesDownloaded: 128,
            totalBytes: 256
        ))
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-reconnect-missing.\(UUID().uuidString)",
            store: store,
            destinationRootURL: root
        )

        _ = try await coordinator.reconnect()
        let record = try await coordinator.record(for: identifier)
        #expect(record?.status == .failed)
        #expect(record?.taskIdentifier == nil)
        #expect(record?.resumeData == nil)
        #expect(record?.lastError == "Background transfer was not found after reconnect.")
    }

    @Test("Cancelling a background download consumer cancels the manager job")
    func cancelsBackgroundDownloadWhenEventConsumerStops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-download-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "background-download-cancel"
        let variant = ModelVariant(
            id: identifier,
            name: "model.aimodel",
            modelID: "example/\(identifier)",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0)
        )
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-download-cancel.\(UUID().uuidString)"
        )
        let events = try await manager.downloadInBackground(
            ModelDownloadRequest(variant: variant, modelName: "Background Cancelled"),
            into: ModelLibrary(rootURL: root.appendingPathComponent("library")),
            using: coordinator
        )
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch {
                // Cancellation is asserted through the manager state below.
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.result
        try await Task.sleep(for: .milliseconds(50))

        #expect(await manager.isDownloading(variantID: identifier) == false)
        try? await coordinator.cancel(identifier: "\(identifier)#0")
    }

    @Test("Model downloads retry transient HTTP failures with bounded backoff")
    func retriesTransientDownloadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-retry-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = Data("retry-model".utf8)
        let downloadURL = URL(string: "https://models.example.test/retry.aimodel")!
        ModelDownloadURLProtocol.configure(body: body, statusCodes: [503, 200], for: downloadURL)
        defer {
            ModelDownloadURLProtocol.reset(for: downloadURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let variant = ModelVariant(
            id: "retry-model",
            name: "model.aimodel",
            modelID: "example/retry",
            source: .directURL,
            downloadURL: downloadURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(body.count)
        )
        let manager = ModelDownloadManager(
            session: session,
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 2, initialBackoff: 0)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let events = try await manager.download(ModelDownloadRequest(variant: variant, modelName: "Retry"), into: library)

        var ready = false
        for try await event in events {
            if case .ready = event.state { ready = true }
        }
        #expect(ready)
        #expect(try await library.contains(modelID: "example/retry"))
    }

    @Test("Failed model downloads emit a failed state and preserve the typed error")
    func reportsFailedDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-failed-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloadURL = URL(string: "https://models.example.test/failed.aimodel")!
        ModelDownloadURLProtocol.configure(body: Data("unavailable".utf8), statusCodes: [404], for: downloadURL)
        defer {
            ModelDownloadURLProtocol.reset(for: downloadURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let variant = ModelVariant(
            id: "failed-model",
            name: "model.aimodel",
            modelID: "example/failed",
            source: .directURL,
            downloadURL: downloadURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 11
        )
        let manager = ModelDownloadManager(
            session: session,
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0)
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Failed"),
            into: ModelLibrary(rootURL: root.appendingPathComponent("library"))
        )

        var states: [ModelDownloadState] = []
        do {
            for try await event in events { states.append(event.state) }
            Issue.record("Expected the HTTP failure to finish the stream with an error.")
        } catch let error as ArchonModelsError {
            #expect(error == .httpFailure(statusCode: 404))
        }
        #expect(states.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Checksum failures prevent a model from becoming ready")
    func rejectsChecksumFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-checksum-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = Data("actual-model".utf8)
        let downloadURL = URL(string: "https://models.example.test/checksum.aimodel")!
        ModelDownloadURLProtocol.configure(body: body, for: downloadURL)
        defer {
            ModelDownloadURLProtocol.reset(for: downloadURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let expectedChecksum = SHA256.hash(data: Data("different-model".utf8)).map { String(format: "%02x", $0) }.joined()
        let variant = ModelVariant(
            id: "checksum-failure",
            name: "model.aimodel",
            modelID: "example/checksum-failure",
            source: .directURL,
            downloadURL: downloadURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64(body.count),
            sha256: expectedChecksum
        )
        let manager = ModelDownloadManager(
            session: session,
            tokenStore: nil,
            policy: ModelDownloadPolicy(maxAttempts: 1, initialBackoff: 0)
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let events = try await manager.download(ModelDownloadRequest(variant: variant, modelName: "Checksum"), into: library)

        var states: [ModelDownloadState] = []
        do {
            for try await event in events { states.append(event.state) }
            Issue.record("Expected the checksum mismatch to finish the stream with an error.")
        } catch let error as ArchonModelsError {
            if case .integrityCheckFailed(let expected, _) = error {
                #expect(expected == expectedChecksum)
            } else {
                Issue.record("Unexpected model download error: \(error)")
            }
        }
        #expect(states.contains { if case .failed = $0 { true } else { false } })
        #expect(try await library.contains(modelID: variant.modelID) == false)
    }

    @Test("Disk-space checks fail before a large model transfer starts")
    func rejectsInsufficientDiskSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-disk-space-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = ModelVariant(
            id: "too-large",
            name: "model.aimodel",
            modelID: "example/too-large",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/too-large.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: Int64.max,
            estimatedMemoryBytes: 1
        )
        let manager = ModelDownloadManager(tokenStore: nil)
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Too Large"),
            into: ModelLibrary(rootURL: root.appendingPathComponent("library"))
        )

        do {
            for try await _ in events {}
            Issue.record("Expected the disk-space check to reject the transfer.")
        } catch let error as ArchonModelsError {
            #expect(error == .insufficientDiskSpace)
        }
    }

    @Test("Gated Hugging Face downloads fail closed without a credential")
    func rejectsUnauthenticatedGatedDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-gated-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = ModelVariant(
            id: "gated-model",
            name: "model.aimodel",
            modelID: "gated/example",
            source: .huggingFace,
            downloadURL: URL(string: "https://huggingface.co/gated/example/resolve/main/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1,
            requiresAuthentication: true
        )
        let manager = ModelDownloadManager(tokenStore: nil)
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Gated Example"),
            into: ModelLibrary(rootURL: root.appendingPathComponent("library"))
        )

        do {
            for try await _ in events {}
            Issue.record("Expected authentication to be required before transfer.")
        } catch let error as ArchonModelsError {
            #expect(error == .authenticationRequired("huggingface.co"))
        }
    }

    @Test("MLX directory variants download every declared resource and install atomically")
    func downloadsAndInstallsDirectoryVariant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-mlx-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let weights = Data("weights".utf8)
        let config = Data(#"{"model_type":"example"}"#.utf8)
        let weightsURL = URL(string: "https://models.example.test/mlx-community/example/model.safetensors")!
        let configURL = URL(string: "https://models.example.test/mlx-community/example/config.json")!
        ModelDownloadURLProtocol.configure(body: weights, for: weightsURL)
        ModelDownloadURLProtocol.configure(body: config, for: configURL)
        defer {
            ModelDownloadURLProtocol.reset(for: weightsURL)
            ModelDownloadURLProtocol.reset(for: configURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let digest: (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let variant = ModelVariant(
            id: "mlx-community/example#mlx",
            name: "MLX package",
            modelID: "mlx-community/example",
            source: .huggingFace,
            downloadURL: weightsURL,
            format: .mlx,
            runtime: .mlx,
            sizeBytes: Int64(weights.count + config.count),
            resources: [
                ModelResource(name: "weights", url: weightsURL, relativePath: "model.safetensors", sizeBytes: Int64(weights.count), sha256: digest(weights)),
                ModelResource(name: "config", url: configURL, relativePath: "config.json", sizeBytes: Int64(config.count), sha256: digest(config))
            ]
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let manager = ModelDownloadManager(session: session, tokenStore: nil)
        let logoURL = URL(string: "https://cdn.example.test/example.png")!
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Example", logoURL: logoURL),
            into: library
        )

        var states: [ModelDownloadState] = []
        for try await event in events { states.append(event.state) }
        let installed = try #require(states.compactMap { state -> InstalledModel? in
            if case .ready(let model) = state { return model }
            return nil
        }.first)

        #expect(FileManager.default.fileExists(atPath: installed.artifactURL.appendingPathComponent("model.safetensors").path))
        #expect(FileManager.default.fileExists(atPath: installed.artifactURL.appendingPathComponent("config.json").path))
        #expect(installed.manifest.modelResources.count == 2)
        #expect(installed.manifest.logoURL == logoURL)
    }

    @Test("Model library writes manifest and artifact into a managed directory")
    func installsManifestAndArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.aimodel")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: source)

        let variant = ModelVariant(
            id: "qwen-coreai",
            name: "source.aimodel",
            modelID: "Qwen/Qwen3",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 5,
            estimatedMemoryBytes: 5
        )
        let manifest = ArchonModelManifest(variant: variant, modelName: "Qwen3")
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: source, manifest: manifest)

        #expect(FileManager.default.fileExists(atPath: installed.directoryURL.appendingPathComponent(ArchonModelManifest.filename).path))
        #expect(try await library.contains(modelID: "Qwen/Qwen3"))
        #expect(try await library.diskUsageBytes() >= 5)
    }

    @Test("Model library atomically replaces an installed model and preserves it on failed updates")
    func atomicallyUpdatesInstalledModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-atomic-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldArtifact = root.appendingPathComponent("old.aimodel")
        let newArtifact = root.appendingPathComponent("new.aimodel")
        try Data("same-size-old".utf8).write(to: oldArtifact)
        try Data("same-size-new".utf8).write(to: newArtifact)
        let variant = ModelVariant(
            id: "atomic-model",
            name: "model.aimodel",
            modelID: "example/atomic",
            source: .directURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 13
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let first = try await library.install(
            downloadedArtifactAt: oldArtifact,
            request: ModelDownloadRequest(variant: variant, modelName: "Atomic")
        )
        #expect(String(data: try Data(contentsOf: first.artifactURL), encoding: .utf8) == "same-size-old")

        _ = try await library.install(
            downloadedArtifactAt: newArtifact,
            request: ModelDownloadRequest(variant: variant, modelName: "Atomic")
        )
        let replaced = try #require(try await library.installedModel(id: first.id))
        #expect(String(data: try Data(contentsOf: replaced.artifactURL), encoding: .utf8) == "same-size-new")

        let invalidArtifact = root.appendingPathComponent("invalid.aimodel")
        try Data("wrong".utf8).write(to: invalidArtifact)
        let mismatchedVariant = ModelVariant(
            id: variant.id,
            name: variant.name,
            modelID: variant.modelID,
            source: variant.source,
            format: variant.format,
            runtime: variant.runtime,
            sizeBytes: 999
        )
        do {
            _ = try await library.install(
                downloadedArtifactAt: invalidArtifact,
                request: ModelDownloadRequest(variant: mismatchedVariant, modelName: "Atomic")
            )
            Issue.record("Expected an invalid update artifact to be rejected.")
        } catch let error as ArchonModelsError {
            guard case .invalidManifest = error else {
                Issue.record("Unexpected update error: \(error)")
                return
            }
        }
        let preserved = try #require(try await library.installedModel(id: first.id))
        #expect(String(data: try Data(contentsOf: preserved.artifactURL), encoding: .utf8) == "same-size-new")
    }

    @Test("Model library deletes only the selected installed model")
    func deletesInstalledModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-model-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("delete.aimodel")
        try Data("delete-me".utf8).write(to: artifact)
        let variant = ModelVariant(
            id: "delete-model",
            name: artifact.lastPathComponent,
            modelID: "example/delete",
            source: .localImport,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 9
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.install(
            downloadedArtifactAt: artifact,
            request: ModelDownloadRequest(variant: variant, modelName: "Delete Me")
        )
        #expect(try await library.contains(modelID: variant.modelID))

        try await library.delete(modelID: installed.id)

        #expect(try await library.contains(modelID: variant.modelID) == false)
        #expect(FileManager.default.fileExists(atPath: installed.directoryURL.path) == false)
    }

    @Test("Directory model packages validate and preserve declared resource files")
    func validatesDirectoryResourcesAndInstallsPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-resource-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)

        let weights = Data("weights".utf8)
        let tokenizer = Data("tokenizer".utf8)
        try weights.write(to: artifact.appendingPathComponent("weights.bin"))
        try tokenizer.write(to: artifact.appendingPathComponent("tokenizer.json"))
        let digest: (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = ArchonModelManifest(
            modelID: "mlx/example",
            modelName: "Example MLX",
            runtime: .mlx,
            format: .mlx,
            modelResources: [ModelResource(
                name: "weights",
                relativePath: "weights.bin",
                sizeBytes: Int64(weights.count),
                sha256: digest(weights)
            )],
            tokenizerResources: [ModelResource(
                name: "tokenizer",
                relativePath: "tokenizer.json",
                sizeBytes: Int64(tokenizer.count),
                sha256: digest(tokenizer)
            )]
        )

        let report = ModelManifestValidator.validate(manifest, artifactAt: artifact)
        #expect(report.isValid)
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: artifact, manifest: manifest)

        #expect(installed.artifactURL.lastPathComponent == "model")
        #expect(installed.resourceURL(manifest.modelResources[0]).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(installed.resourceURL(manifest.tokenizerResources[0])?.lastPathComponent == "tokenizer.json")
        #expect(try await library.installedModels().count == 1)
    }

    @Test("Importing a selected package root follows its sidecar artifact path")
    func importsSidecarPackageRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-sidecar-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.aimodel")
        try Data("model".utf8).write(to: artifact)

        let manifest = ArchonModelManifest(
            modelID: "apple/example",
            modelName: "Example Core AI",
            runtime: .coreAI,
            format: .aimodel,
            artifactPath: artifact.lastPathComponent,
            modelSizeBytes: 5
        )
        let manifestURL = root.appendingPathComponent(ArchonModelManifest.filename)
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: root)

        #expect(installed.manifest.modelID == "apple/example")
        #expect(installed.artifactURL.lastPathComponent == "model.aimodel")
        #expect(try await library.installedModels().count == 1)
    }

    @Test("Supplied manifests resolve their artifact path from a package directory")
    func importsSuppliedPackageManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-supplied-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.aimodel")
        try Data("model".utf8).write(to: artifact)

        let manifest = ArchonModelManifest(
            modelID: "apple/supplied",
            modelName: "Supplied Core AI",
            runtime: .coreAI,
            format: .aimodel,
            artifactPath: artifact.lastPathComponent,
            modelSizeBytes: 5
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.importArtifact(at: root, manifest: manifest)

        #expect(installed.artifactURL.lastPathComponent == "model.aimodel")
        #expect(String(data: try Data(contentsOf: installed.artifactURL), encoding: .utf8) == "model")
    }

    @Test("Model library reports newer catalog revisions without downloading them")
    func reportsAvailableModelUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archon-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.mlx")
        try Data("model".utf8).write(to: artifact)

        let manifest = ArchonModelManifest(
            modelID: "mlx/example",
            modelName: "Example MLX",
            sourceRepository: "example/repository",
            sourceRevision: "old-revision",
            runtime: .mlx,
            format: .mlx,
            modelSizeBytes: 5
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        _ = try await library.importArtifact(at: artifact, manifest: manifest)

        let variant = ModelVariant(
            id: "example/repository#model.mlx",
            name: "model.mlx",
            modelID: "example/repository",
            source: .huggingFace,
            format: .mlx,
            runtime: .mlx
        )
        let catalog = StaticModelCatalog(models: [ModelDescriptor(
            id: "example/repository",
            name: "Example MLX",
            publisher: "Example",
            source: .huggingFace,
            revision: "new-revision",
            variants: [variant]
        )])

        let updates = try await library.checkForUpdates(using: catalog)

        #expect(updates.count == 1)
        #expect(updates[0].currentRevision == "old-revision")
        #expect(updates[0].availableRevision == "new-revision")
        #expect(updates[0].variant?.id == variant.id)
    }

    @Test("Model update replaces the selected installation when the catalog variant ID changes")
    func updateUsesExistingInstallationIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-update-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let oldArtifact = root.appendingPathComponent("old.aimodel")
        let newArtifact = root.appendingPathComponent("new.aimodel")
        try Data("old-model".utf8).write(to: oldArtifact)
        try Data("new-model".utf8).write(to: newArtifact)

        let oldVariant = ModelVariant(
            id: "old-variant",
            name: "model.aimodel",
            modelID: "example/update-identity",
            source: .directURL,
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 9
        )
        let library = ModelLibrary(rootURL: root.appendingPathComponent("library"))
        let installed = try await library.install(
            downloadedArtifactAt: oldArtifact,
            request: ModelDownloadRequest(variant: oldVariant, modelName: "Update Identity")
        )

        let newVariant = ModelVariant(
            id: "new-variant",
            name: "model.aimodel",
            modelID: oldVariant.modelID,
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/new.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 9
        )
        let streamProvider: ModelByteStreamProvider = { request in
            let (stream, continuation) = AsyncThrowingStream<UInt8, Error>.makeStream()
            Task {
                for byte in Data("new-model".utf8) {
                    continuation.yield(byte)
                }
                continuation.finish()
            }
            return (stream, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "9"]
            )!)
        }
        let manager = ModelDownloadManager(tokenStore: nil, byteStreamProvider: streamProvider)
        let candidate = ModelUpdateCandidate(
            id: installed.id,
            installedModelID: installed.id,
            sourceRepository: oldVariant.modelID,
            currentRevision: "old-revision",
            availableRevision: "new-revision",
            variant: newVariant
        )

        let events = try await manager.update(candidate, into: library)
        for try await _ in events {}

        let replaced = try #require(try await library.installedModel(id: installed.id))
        #expect(replaced.id == installed.id)
        #expect(String(data: try Data(contentsOf: replaced.artifactURL), encoding: .utf8) == "new-model")
        #expect(try await library.installedModels().count == 1)
    }

    @Test("Background download records survive store recreation")
    func persistsBackgroundDownloadRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("downloads.json")
        let request = ModelBackgroundDownloadRequest(
            identifier: "qwen-background",
            url: URL(string: "https://models.example.test/qwen.aimodel")!,
            destinationURL: root.appendingPathComponent("qwen.aimodel"),
            headers: ["Authorization": "Bearer test", "X-Client": "archon-test"]
        )
        let store = FileModelBackgroundDownloadStore(fileURL: storeURL)
        try await store.save(ModelBackgroundDownloadRecord(
            request: request,
            taskIdentifier: 42,
            resumeData: Data("resume-secret".utf8),
            status: .downloading,
            bytesDownloaded: 128,
            totalBytes: 256
        ))

        let persistedText = try String(decoding: Data(contentsOf: storeURL), as: UTF8.self)
        #expect(!persistedText.contains("resume-secret"))
        #expect(!persistedText.contains("Bearer test"))

        let reloaded = FileModelBackgroundDownloadStore(fileURL: storeURL)
        let record = try await reloaded.record(for: request.identifier)
        #expect(record?.request.identifier == request.identifier)
        #expect(record?.request.headers["Authorization"] == nil)
        #expect(record?.request.headers["X-Client"] == "archon-test")
        #expect(record?.status == .downloading)
        #expect(record?.bytesDownloaded == 128)
        #expect(record?.totalBytes == 256)
    }

    @Test("Background coordinator rejects non-network or non-file requests before starting")
    func validatesBackgroundDownloadRequest() async throws {
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background.\(UUID().uuidString)"
        )
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("model.part")

        await #expect(throws: ModelBackgroundTransferError.self) {
            _ = try await coordinator.start(ModelBackgroundDownloadRequest(
                identifier: "local-file",
                url: URL(fileURLWithPath: "/tmp/model"),
                destinationURL: destination
            ))
        }

        await #expect(throws: ModelBackgroundTransferError.self) {
            _ = try await coordinator.start(ModelBackgroundDownloadRequest(
                identifier: "remote-destination",
                url: URL(string: "https://models.example.test/model")!,
                destinationURL: URL(string: "https://models.example.test/model.part")!
            ))
        }
    }

    @Test("Background model manager enforces license policy before scheduling transfer")
    func enforcesBackgroundLicensePolicyBeforeTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-license-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = ModelVariant(
            id: "background-license-model",
            name: "model.aimodel",
            modelID: "example/background-license",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            licensePolicy: ModelLicensePolicy(unknownBehavior: .denied)
        )
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-license.\(UUID().uuidString)"
        )
        let events = try await manager.downloadInBackground(
            ModelDownloadRequest(
                variant: variant,
                modelName: "Background License",
                license: ModelLicenseMetadata(identifier: "unknown-license")
            ),
            into: ModelLibrary(rootURL: root.appendingPathComponent("library")),
            using: coordinator
        )

        do {
            for try await _ in events {}
            Issue.record("Expected the background license policy to reject the download.")
        } catch let error as ArchonModelsError {
            #expect(error == .licenseDenied("unknown-license"))
        }
        #expect(await manager.isDownloading(variantID: variant.id) == false)
    }

    @Test("Background resume rejects reconstructed metadata for another variant")
    func rejectsMismatchedReconstructedRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archon-background-relaunch-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = ModelVariant(
            id: "background-relaunch-model",
            name: "model.aimodel",
            modelID: "example/background-relaunch",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            sizeBytes: 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            licensePolicy: ModelLicensePolicy(unknownBehavior: .denied)
        )
        let coordinator = ModelBackgroundTransferCoordinator(
            sessionIdentifier: "com.archon.tests.background-relaunch.\(UUID().uuidString)"
        )
        await #expect(throws: ArchonModelsError.self) {
            _ = try await manager.resumeInBackground(
                variantID: variant.id,
                request: ModelDownloadRequest(
                    variant: ModelVariant(
                        id: "another-variant",
                        name: variant.name,
                        modelID: variant.modelID,
                        source: variant.source,
                        downloadURL: variant.downloadURL,
                        format: variant.format,
                        runtime: variant.runtime
                    ),
                    modelName: "Background Relaunch"
                ),
                into: ModelLibrary(rootURL: root.appendingPathComponent("library")),
                using: coordinator
            )
        }
    }
}
