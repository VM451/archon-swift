import CryptoKit
import Foundation
import Testing
@testable import ArchonModels
import ArchonCore

private final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var bodiesByPath: [String: Data] = [:]
    nonisolated(unsafe) static var statusCodes: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodiesByPath[request.url?.path ?? ""] ?? Self.body
        let statusCode = Self.statusCodes.isEmpty ? 200 : Self.statusCodes.removeFirst()
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
            estimatedMemoryBytes: 3_000_000_000
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
          "cardData": {"license": "apache-2.0", "language": ["en", "zh"]},
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
        ModelDownloadURLProtocol.body = body
        defer {
            ModelDownloadURLProtocol.body = Data()
            ModelDownloadURLProtocol.bodiesByPath = [:]
            ModelDownloadURLProtocol.statusCodes = []
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
            downloadURL: URL(string: "https://models.example.test/model.aimodel"),
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
            store: store
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
        ModelDownloadURLProtocol.body = body
        ModelDownloadURLProtocol.statusCodes = [503, 200]
        defer {
            ModelDownloadURLProtocol.body = Data()
            ModelDownloadURLProtocol.statusCodes = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
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
        ModelDownloadURLProtocol.body = Data("unavailable".utf8)
        ModelDownloadURLProtocol.statusCodes = [404]
        defer {
            ModelDownloadURLProtocol.body = Data()
            ModelDownloadURLProtocol.statusCodes = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let variant = ModelVariant(
            id: "failed-model",
            name: "model.aimodel",
            modelID: "example/failed",
            source: .directURL,
            downloadURL: URL(string: "https://models.example.test/failed.aimodel"),
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
        ModelDownloadURLProtocol.body = body
        defer {
            ModelDownloadURLProtocol.body = Data()
            ModelDownloadURLProtocol.statusCodes = []
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
            downloadURL: URL(string: "https://models.example.test/checksum.aimodel"),
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
            sizeBytes: Int64.max
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
        ModelDownloadURLProtocol.bodiesByPath = [
            "/mlx-community/example/model.safetensors": weights,
            "/mlx-community/example/config.json": config
        ]
        defer { ModelDownloadURLProtocol.bodiesByPath = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let digest: (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let weightsURL = URL(string: "https://models.example.test/mlx-community/example/model.safetensors")!
        let configURL = URL(string: "https://models.example.test/mlx-community/example/config.json")!
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
        let events = try await manager.download(ModelDownloadRequest(variant: variant, modelName: "Example"), into: library)

        var states: [ModelDownloadState] = []
        for try await event in events { states.append(event.state) }
        let installed = try #require(states.compactMap { state -> InstalledModel? in
            if case .ready(let model) = state { return model }
            return nil
        }.first)

        #expect(FileManager.default.fileExists(atPath: installed.artifactURL.appendingPathComponent("model.safetensors").path))
        #expect(FileManager.default.fileExists(atPath: installed.artifactURL.appendingPathComponent("config.json").path))
        #expect(installed.manifest.modelResources.count == 2)
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
