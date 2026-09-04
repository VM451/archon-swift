import Foundation
import Testing
@testable import ArchonAgent

@Suite("MLX Local Provider & On-Device Fallback Tests")
struct MLXProviderTests {

    @Test("MLX provider defaults to Gemma 4 E2B and advertises local streaming")
    func defaultModelConfiguration() {
        let provider = MLXLocalProvider()

        #expect(provider.source == .huggingFace(
            id: MLXLocalProvider.defaultModelID,
            revision: "main"
        ))
        #expect(provider.id == "mlx.\(MLXLocalProvider.defaultModelID)@main")
        #expect(provider.capabilities.isOnDevice)
        #expect(provider.capabilities.supportsStreaming)
        #expect(provider.capabilities.supportsToolCalling)
    }

    @Test("MLX provider accepts arbitrary model IDs and local model directories")
    func modelSourceConfiguration() {
        let remote = MLXLocalProvider(model: "mlx-community/Qwen3-0.6B-4bit")
        #expect(remote.source.identifier == "mlx-community/Qwen3-0.6B-4bit@main")

        let localDirectory = URL(filePath: "/tmp/archon-gemma")
        let local = MLXLocalProvider(localModelDirectory: localDirectory)
        #expect(local.source == .localDirectory(localDirectory))
        #expect(local.source.isLocal)
    }

    @Test("MLX validates the prompt before loading model weights")
    func emptyPromptDoesNotLoadModel() async {
        let provider = MLXLocalProvider()

        await #expect(throws: MLXLocalProviderError.self) {
            _ = try await provider.generate(prompt: [], tools: [], options: GenerationOptions())
        }
    }

    @Test("ZeroCloudMode blocks remote MLX model downloads")
    func zeroCloudBlocksRemoteModelDownload() async {
        let provider = MLXLocalProvider()

        await ZeroCloudMode.withEnabled {
            await #expect(throws: GraphError.self) {
                _ = try await provider.generate(
                    prompt: [.user("hello")],
                    tools: [],
                    options: GenerationOptions()
                )
            }
        }
    }
}

@Suite("Automatic On-Device Backend Selection Tests")
struct OnDeviceProviderTests {

    @Test("Automatic provider uses MLX when Apple Foundation Models are unavailable")
    func selectsMLXWhenAppleModelIsUnavailable() {
        let provider = OnDeviceProvider(
            strategy: .adaptive(preference: .adaptive),
            hardwareProfile: .iPhone12Base,
            appleFoundationModelAvailable: false
        )

        #expect(provider.backend == .mlx)
        #expect(provider.id.hasPrefix("mlx."))
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("Automatic provider keeps Apple Foundation Models as the preferred backend")
    func selectsAppleFoundationModelWhenAvailable() {
        let provider = OnDeviceProvider(appleFoundationModelAvailable: true)

        #expect(provider.backend == .appleFoundationModel)
        #expect(provider.id == "apple.foundation.default")
    }
}
