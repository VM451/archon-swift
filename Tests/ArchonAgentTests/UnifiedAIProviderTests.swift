import Foundation
import Testing
@testable import ArchonAgent

@Suite("Unified Archon AI Provider & Model Architecture Tests")
struct UnifiedAIProviderTests {

    @Test("ArchonAI resolves Apple Foundation Model target")
    func resolvesAppleFoundation() {
        let provider = ArchonAI.model(.appleFoundationModel())
        #expect(provider.id == "apple.foundation.default")
        #expect(provider.capabilities.isOnDevice)
        #expect(provider.capabilities.supportsStreaming)
    }

    @Test("ArchonAI resolves Apple Private Cloud Compute target")
    func resolvesPrivateCloudCompute() {
        let provider = ArchonAI.model(.privateCloudCompute())
        #expect(provider.id == "apple.pcc.default")
        #expect(!provider.capabilities.isOnDevice)
        #expect(provider.capabilities.maxContextTokens >= 65536)
    }

    @Test("ArchonAI resolves Apple Core AI target with Gemma 4")
    func resolvesCoreAI() {
        let provider = ArchonAI.model(.coreAI())
        #expect(provider.id.hasPrefix("coreai."))
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("ArchonAI resolves Apple MLX target with Gemma 4")
    func resolvesMLX() {
        let provider = ArchonAI.model(.mlx())
        #expect(provider.id.hasPrefix("mlx."))
        #expect(provider.capabilities.isOnDevice)
    }

    @Test("ArchonAI resolves Google Gemini, Anthropic Claude, and OpenAI targets")
    func resolvesCloudProviders() {
        let gemini = ArchonAI.model(.gemini(apiKey: "mock-key", model: "gemini-2.5-flash"))
        #expect(gemini.id == "google.gemini-2.5-flash")

        let claude = ArchonAI.model(.claude(apiKey: "mock-key", model: "claude-3-7-sonnet-20250219"))
        #expect(claude.id == "anthropic.claude-3-7-sonnet-20250219")

        let openAI = ArchonAI.model(.openAI(apiKey: "mock-key", model: "gpt-4o"))
        #expect(openAI.id == "openai.gpt-4o")

    }

    @Test("ArchonAI ergonomic factory shortcuts instantiate correct providers")
    func factoryShortcuts() {
        let pcc = ArchonAI.privateCloudCompute
        #expect(pcc.id == "apple.pcc.default")

        let afm = ArchonAI.appleFoundation
        #expect(afm.id == "apple.foundation.default")

        let auto = ArchonAI.auto
        #expect(auto.capabilities.isOnDevice)
    }

    @Test("PrivateCloudComputeProvider generates and streams response offline")
    func privateCloudComputeGeneration() async throws {
        let pcc = PrivateCloudComputeProvider(simulatedDelay: 0.001)
        pcc.registerMockResponse(forPromptContaining: "summarize", response: "PCC Summary: Done")

        let response = try await pcc.generate(prompt: [.user("Please summarize this data")])
        #expect(response.text == "PCC Summary: Done")
        #expect(response.finishReason == "stop")
        #expect(response.usage?.totalTokens ?? 0 > 0)

        var streamedChunks: [String] = []
        for try await chunk in pcc.stream(prompt: [.user("Please summarize this data")]) {
            if let text = chunk.deltaText {
                streamedChunks.append(text)
            }
        }
        #expect(!streamedChunks.isEmpty)
    }

    @Test("FoundationModelsBridge formats transcripts and schemas cleanly")
    func foundationModelsBridgeFormatting() {
        let transcript = FoundationModelsBridge.formatTranscript(for: [
            .system("You are an Archon agent."),
            .user("How do actors work?"),
            .assistant("Actors protect mutable state.")
        ])

        #expect(transcript.systemInstruction == "You are an Archon agent.")
        #expect(transcript.userPrompt.contains("How do actors work?"))
        #expect(transcript.userPrompt.contains("Actors protect mutable state."))

        let tool = ToolDefinition(
            name: "search_db",
            description: "Search SQLite database",
            parametersJSONSchema: ["type": AnySendable("object")]
        )
        let schema = FoundationModelsBridge.exportToolsSchema(from: [tool])
        #expect(schema.count == 1)
        #expect((schema.first?["name"] as? String) == "search_db")
    }
}
