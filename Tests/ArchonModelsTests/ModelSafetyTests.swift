import Foundation
import Testing
import ArchonCore
@testable import ArchonModels

struct ModelSafetyTests {
    private let device = ArchonDeviceCapabilities(
        platform: .macOS,
        osVersion: ArchonOSVersion(major: 27),
        physicalMemoryBytes: 16_000_000_000,
        availableMemoryBytes: 12_000_000_000,
        processorCount: 8,
        deviceArchitecture: "arm64",
        supportsAppleFoundationModels: false,
        supportsCoreAI: true
    )

    @Test("Model downloads reject loopback URLs before invoking transport")
    func rejectsLoopbackURL() async throws {
        let variant = ModelVariant(
            id: "loopback-model",
            name: "model.aimodel",
            modelID: "example/loopback",
            source: .directURL,
            downloadURL: URL(string: "http://127.0.0.1/model.aimodel"),
            format: .aimodel,
            runtime: .coreAI,
            supportedPlatforms: [.macOS],
            sizeBytes: 1,
            estimatedMemoryBytes: 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            byteStreamProvider: { _ in
                throw ArchonModelsError.invalidResponse
            }
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Loopback"),
            into: ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-loopback-\(UUID().uuidString)")),
            on: device
        )

        do {
            for try await _ in events {}
            Issue.record("Expected the loopback URL to be rejected.")
        } catch let error as ArchonModelsError {
            #expect(error == .invalidResponse)
        }
    }

    @Test("Model downloads enforce an absolute byte cap without Content-Length reliance")
    func enforcesAbsoluteDownloadCap() async throws {
        let body = Data(repeating: 0x41, count: 2_048)
        let url = URL(string: "https://models.example.test/oversized.aimodel")!
        let provider: ModelByteStreamProvider = { request in
            let stream = AsyncThrowingStream<UInt8, Error> { continuation in
                for byte in body { continuation.yield(byte) }
                continuation.finish()
            }
            let response = HTTPURLResponse(
                url: request.url ?? url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": String(body.count)]
            )!
            return (stream, response)
        }
        let variant = ModelVariant(
            id: "capped-model",
            name: "model.aimodel",
            modelID: "example/capped",
            source: .directURL,
            downloadURL: url,
            format: .aimodel,
            runtime: .coreAI,
            supportedPlatforms: [.macOS],
            sizeBytes: nil,
            estimatedMemoryBytes: 1
        )
        let manager = ModelDownloadManager(
            tokenStore: nil,
            policy: ModelDownloadPolicy(maximumDownloadBytes: 1_024),
            byteStreamProvider: provider
        )
        let events = try await manager.download(
            ModelDownloadRequest(variant: variant, modelName: "Capped"),
            into: ModelLibrary(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archon-capped-\(UUID().uuidString)")),
            on: device
        )

        do {
            for try await _ in events {}
            Issue.record("Expected the absolute download cap to fail the transfer.")
        } catch let error as ArchonModelsError {
            #expect(error == .downloadSizeExceeded(maximum: 1_024))
        }
    }
}
