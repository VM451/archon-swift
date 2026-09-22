import Testing
import Foundation
@testable import ArchonAgent

// Deterministic coverage for the OpenAI-compatible transport shared by
// `OpenAIProvider`, `MistralProvider`, `GrokProvider`, and `NvidiaProvider`.
// Live SSE/generate round trips need network and stay a consuming-app gate;
// these tests pin the pure request builder, the SSE event parser, and the
// advertised capabilities/factory wiring instead.

@Suite("OpenAI-Compatible Streaming Tests")
struct OpenAICompatibleStreamingTests {

    private func bodyJSON(
        stream: Bool = false,
        options: GenerationOptions = GenerationOptions(),
        tools: [ToolDefinition] = []
    ) throws -> [String: Any] {
        let data = try OpenAIProvider.requestBody(
            model: "mistral-medium-3-5",
            prompt: [.user("hi")],
            tools: tools,
            options: options,
            stream: stream
        )
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Streaming requests set the stream flag; generate omits it")
    func streamFlag() throws {
        let streamed = try bodyJSON(stream: true)
        #expect(streamed["stream"] as? Bool == true)
        let single = try bodyJSON(stream: false)
        #expect(single["stream"] == nil)
    }

    @Test("JSON mode requests json_object response_format")
    func jsonResponseFormat() throws {
        let options = GenerationOptions(responseFormatJSON: true)
        let json = try bodyJSON(options: options)
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        let plain = try bodyJSON()
        #expect(plain["response_format"] == nil)
    }

    @Test("Sampling knobs and tools are forwarded")
    func samplingAndTools() throws {
        let options = GenerationOptions(
            temperature: 0.3,
            topP: 0.9,
            maxTokens: 128,
            stopSequences: ["END"]
        )
        let tool = ToolDefinition(name: "lookup", description: "Look things up.")
        let json = try bodyJSON(options: options, tools: [tool])
        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["top_p"] as? Double == 0.9)
        #expect(json["max_tokens"] as? Int == 128)
        #expect((json["stop"] as? [String]) == ["END"])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect((tools[0]["function"] as? [String: Any])?["name"] as? String == "lookup")
    }

    @Test("Nested tool schemas serialize without trapping")
    func nestedSchemaUnwrap() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Search.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable("string"),
                    "limit": AnySendable(10),
                    "filters": AnySendable([AnySendable("a"), AnySendable(true)]),
                ]),
            ]
        )
        let json = try bodyJSON(tools: [tool])
        let tools = try #require(json["tools"] as? [[String: Any]])
        let fn = try #require(tools[0]["function"] as? [String: Any])
        let params = try #require(fn["parameters"] as? [String: Any])
        #expect(params["type"] as? String == "object")
        let props = try #require(params["properties"] as? [String: Any])
        #expect(props["query"] as? String == "string")
        #expect(props["limit"] as? Int == 10)
        #expect((props["filters"] as? [Any])?.count == 2)
    }

    @Test("SSE content deltas parse into text chunks")
    func contentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#
        let chunk = OpenAIProvider.parseStreamLine(line)
        #expect(chunk?.deltaText == "Hello")
        #expect(chunk?.isFinished == false)
    }

    @Test("SSE tool-call deltas parse with wire index preserved")
    func toolCallDelta() {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"index":2,"id":"call_1","function":{"name":"lookup","arguments":"{\"q\":"}}]}}]}"#
        let chunk = OpenAIProvider.parseStreamLine(line)
        let calls = expectIfNotNil(chunk?.toolCallChunks)
        #expect(calls?.count == 1)
        #expect(calls?.first?.index == 2)
        #expect(calls?.first?.id == "call_1")
        #expect(calls?.first?.name == "lookup")
    }

    @Test("SSE parser ignores comments, blanks, malformed, and empty deltas")
    func ignoredLines() {
        #expect(OpenAIProvider.parseStreamLine(": ping") == nil)
        #expect(OpenAIProvider.parseStreamLine("") == nil)
        #expect(OpenAIProvider.parseStreamLine("data: not-json") == nil)
        #expect(OpenAIProvider.parseStreamLine("event: message") == nil)
        #expect(OpenAIProvider.parseStreamLine("data: [DONE]") == nil)
        #expect(OpenAIProvider.parseStreamLine(#"data: {"choices":[{"delta":{}}]}"#) == nil)
    }

    @Test("Terminal marker detection is whitespace tolerant")
    func doneDetection() {
        #expect(OpenAIProvider.isStreamDoneLine("data: [DONE]"))
        #expect(OpenAIProvider.isStreamDoneLine("  data: [DONE]  "))
        #expect(!OpenAIProvider.isStreamDoneLine("data: {}"))
        #expect(!OpenAIProvider.isStreamDoneLine(": [DONE]"))
    }

    @Test("OpenAI-compatible providers advertise incremental streaming")
    func streamingCapabilities() {
        #expect(OpenAIProvider(apiKey: "k").capabilities.supportsStreaming)
        #expect(MistralProvider(apiKey: "k").capabilities.supportsStreaming)
        #expect(GrokProvider(apiKey: "k").capabilities.supportsStreaming)
        #expect(NvidiaProvider(apiKey: "k").capabilities.supportsStreaming)
    }

    @Test("Mistral provider defaults to Medium 3.5 on the Mistral endpoint")
    func mistralDefaults() {
        let provider = MistralProvider(apiKey: "k")
        #expect(provider.id == "mistral.mistral-medium-3-5")
        #expect(provider.capabilities.supportsToolCalling)
    }

    @Test("Mistral factory resolves through the unified enum and shortcut")
    func mistralFactory() {
        let viaEnum = ArchonAI.model(.mistral(apiKey: "k"))
        #expect(viaEnum is MistralProvider)
        #expect(viaEnum.id == "mistral.mistral-medium-3-5")
        let viaShortcut = ArchonAI.mistral(apiKey: "k", model: "mistral-large-2512")
        #expect(viaShortcut.id == "mistral.mistral-large-2512")
    }
}

private func expectIfNotNil<T>(_ value: T?) -> T? {
    if value == nil {
        Issue.record("Expected non-nil value")
    }
    return value
}
