import Foundation
import Testing

@testable import ArchonAgent

// MARK: - Fakes

private actor FakeGate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = true) { self.open = open }

    func close() { open = false }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitIfClosed() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class FakeProvider: LLMProvider, @unchecked Sendable {
    let id = "fake"
    let capabilities: ModelCapabilities
    let gate: FakeGate
    private let lock = NSLock()
    private var scripts: [[ModelResponseChunk]]
    private var prompts: [[ChatMessage]] = []

    init(capabilities: ModelCapabilities = .cloudStandard, scripts: [[ModelResponseChunk]], gate: FakeGate) {
        self.capabilities = capabilities
        self.scripts = scripts
        self.gate = gate
    }

    var promptCount: Int { lock.withLock { prompts.count } }
    var lastPrompt: [ChatMessage]? { lock.withLock { prompts.last } }

    func generate(prompt: [ChatMessage], tools: [ToolDefinition], options: GenerationOptions) async throws -> ModelResponse {
        ModelResponse(text: "")
    }

    func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        let script = lock.withLock { () -> [ModelResponseChunk] in
            prompts.append(prompt)
            return scripts.isEmpty ? [ModelResponseChunk(deltaText: "ok", isFinished: true)] : scripts.removeFirst()
        }
        let (stream, continuation) = AsyncThrowingStream<ModelResponseChunk, Error>.makeStream()
        Task {
            await gate.waitIfClosed()
            for chunk in script { continuation.yield(chunk) }
            continuation.finish()
        }
        return stream
    }
}

private final class FakeRecognizer: StreamingSpeechRecognizer, @unchecked Sendable {
    let id = "fake-stt"
    let supportsOnDevice = true
    private let lock = NSLock()
    private var begins = 0
    private var appendedChunks = 0
    private var finals: [String] = []
    private var live: AsyncThrowingStream<PartialTranscript, Error>.Continuation?

    var beginCount: Int { lock.withLock { begins } }
    var appendedCount: Int { lock.withLock { appendedChunks } }

    func enqueueFinal(_ text: String) { lock.withLock { finals.append(text) } }
    func emitPartial(_ text: String) { lock.withLock { live }?.yield(PartialTranscript(text: text, isFinal: false)) }

    func begin() async throws -> AsyncThrowingStream<PartialTranscript, Error> {
        let (stream, continuation) = AsyncThrowingStream<PartialTranscript, Error>.makeStream()
        lock.withLock {
            begins += 1
            live = continuation
        }
        return stream
    }

    func append(samples: [Float], sampleRate: Int) async throws {
        lock.withLock { appendedChunks += 1 }
    }

    func end() async throws -> PartialTranscript? {
        let next = lock.withLock { () -> String? in finals.isEmpty ? nil : finals.removeFirst() }
        guard let next else { return nil }
        return PartialTranscript(text: next, isFinal: true)
    }
}

private actor FakeSynthesizer: SpeechSynthesizer {
    let id = "fake-tts"
    let gate: FakeGate
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private(set) var isSpeaking = false

    init(gate: FakeGate) { self.gate = gate }

    func speak(text: String) async throws {
        spoken.append(text)
        isSpeaking = true
        defer { isSpeaking = false }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { await gate.waitIfClosed(); continuation.resume() }
                }
            } onCancel: {}
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    func stop() async { stopCount += 1 }
}

private actor EventLog {
    private(set) var events: [RealtimeEvent] = []
    func append(_ event: RealtimeEvent) { events.append(event) }
    func contains(where match: (RealtimeEvent) -> Bool) -> Bool { events.contains(where: match) }
    func count(where match: (RealtimeEvent) -> Bool) -> Int { events.filter(match).count }
}

private func waitUntil(
    _ description: String = "",
    timeout: Duration = .seconds(3),
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let start = clock.now
    while await !condition() {
        if clock.now - start > timeout {
            Issue.record("Timed out waiting: \(description)")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func speechChunk(count: Int = 1600) -> [Float] { [Float](repeating: 0.5, count: count) }
private func silenceChunk(count: Int = 1600) -> [Float] { [Float](repeating: 0, count: count) }

private func jpegFrame(source: RealtimeFrameSource = .screen) -> RealtimeFrame {
    RealtimeFrame(source: source, mimeType: "image/jpeg", imageData: Data(repeating: 0xFF, count: 64))
}

// MARK: - Suite

@Suite("Realtime Session Tests")
struct RealtimeSessionTests {
    private func makeSession(
        scripts: [[ModelResponseChunk]] = [[ModelResponseChunk(deltaText: "hello", isFinished: true)]],
        gate: FakeGate? = nil,
        policy: RealtimeTurnPolicy = RealtimeTurnPolicy(speakResponsesAloud: false),
        capabilities: ModelCapabilities = .cloudStandard,
        recognizer: FakeRecognizer? = nil,
        synthesizer: FakeSynthesizer? = nil
    ) async throws -> (RealtimeSession, FakeProvider, FakeRecognizer, EventLog, Task<Void, Never>) {
        let activeGate = gate ?? FakeGate()
        let provider = FakeProvider(capabilities: capabilities, scripts: scripts, gate: activeGate)
        let stt = recognizer ?? FakeRecognizer()
        let session = try await RealtimeSession(
            provider: provider,
            recognizer: stt,
            synthesizer: synthesizer,
            policy: policy
        )
        let log = EventLog()
        let consumer = Task {
            for await event in session.events { await log.append(event) }
        }
        return (session, provider, stt, log, consumer)
    }

    @Test("Policy validation rejects unusable turn parameters")
    func policyValidation() {
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(vadEnergyThreshold: 0).validated() }
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(minSpeechMs: 10).validated() }
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(silenceHangoverMs: 50_000).validated() }
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(maxUtteranceSeconds: 0).validated() }
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(maxBufferedFrames: 0).validated() }
        #expect(throws: RealtimeError.self) { try RealtimeTurnPolicy(sampleRate: 44_100).validated() }
    }

    @Test("VAD opens a turn on sustained speech and closes on silence")
    func vadTurnBoundaries() {
        var vad = VoiceActivityDetector(policy: RealtimeTurnPolicy())
        #expect(vad.ingest(samples: silenceChunk(), chunkMs: 100) == nil)
        #expect(vad.ingest(samples: speechChunk(), chunkMs: 100) == nil)
        #expect(vad.ingest(samples: speechChunk(), chunkMs: 100) == nil)
        #expect(vad.ingest(samples: speechChunk(), chunkMs: 100) == .speechStarted)
        for _ in 0..<6 {
            #expect(vad.ingest(samples: silenceChunk(), chunkMs: 100) == nil)
        }
        let end = vad.ingest(samples: silenceChunk(), chunkMs: 100)
        guard case .speechEnded = end else {
            Issue.record("Expected speechEnded after the silence hangover.")
            return
        }
    }

    @Test("VAD force-closes an overlong utterance")
    func vadMaxUtterance() {
        var vad = VoiceActivityDetector(
            policy: RealtimeTurnPolicy(minSpeechMs: 100, silenceHangoverMs: 10_000, maxUtteranceSeconds: 2)
        )
        #expect(vad.ingest(samples: speechChunk(), chunkMs: 100) == .speechStarted)
        var end: VoiceActivityEvent?
        for _ in 0..<25 {
            if let boundary = vad.ingest(samples: speechChunk(), chunkMs: 100) {
                end = boundary
                break
            }
        }
        guard case .speechEnded = end else {
            Issue.record("Expected a forced speechEnded at the utterance cap.")
            return
        }
    }

    @Test("Text turn streams chunks and commits history")
    func textTurn() async throws {
        let (session, _, _, log, consumer) = try await makeSession(
            scripts: [[
                ModelResponseChunk(deltaText: "hel"),
                ModelResponseChunk(deltaText: "lo", isFinished: true)
            ]]
        )
        defer { consumer.cancel() }
        try await session.start()
        try await session.sendText("hi")
        await waitUntil("response completed") {
            await log.contains { if case .responseCompleted = $0 { return true }; return false }
        }
        let history = await session.transcript()
        #expect(history.contains { $0.role == .user && $0.content == "hi" })
        #expect(history.contains { $0.role == .assistant && $0.content == "hello" })
        await waitUntil("listening state restored") {
            await log.contains { $0 == .stateChanged(.listening) }
        }
    }

    @Test("Text barge-in cancels the stale turn and answers the new message")
    func textBargeIn() async throws {
        let gate = FakeGate(open: false)
        let (session, provider, _, log, consumer) = try await makeSession(
            scripts: [
                [ModelResponseChunk(deltaText: "stale", isFinished: true)],
                [ModelResponseChunk(deltaText: "fresh", isFinished: true)]
            ],
            gate: gate
        )
        defer { consumer.cancel() }
        try await session.start()
        try await session.sendText("first")
        await waitUntil("first generation in flight") { await provider.promptCount == 1 }
        try await session.sendText("second")
        await waitUntil("interruption emitted") {
            await log.contains { $0 == .interrupted(.userText) }
        }
        await gate.release()
        await waitUntil("second response completed") {
            await log.count { if case .responseCompleted = $0 { return true }; return false } == 1
        }
        let history = await session.transcript()
        #expect(history.filter { $0.role == .assistant }.map(\.content) == ["fresh"])
        #expect(await provider.promptCount == 2)
    }

    @Test("Spoken turn transcribes on silence and generates a reply")
    func spokenTurn() async throws {
        let recognizer = FakeRecognizer()
        await recognizer.enqueueFinal("what time is it")
        let (session, _, _, log, consumer) = try await makeSession(recognizer: recognizer)
        defer { consumer.cancel() }
        try await session.start()
        for _ in 0..<3 { try await session.ingestAudio(samples: speechChunk(), sampleRate: 16_000) }
        await waitUntil("speech started") {
            await log.contains { $0 == .speechStarted }
        }
        for _ in 0..<8 { try await session.ingestAudio(samples: silenceChunk(), sampleRate: 16_000) }
        await waitUntil("final transcript") {
            await log.contains { $0 == .finalTranscript("what time is it") }
        }
        await waitUntil("spoken response completed") {
            await log.contains { if case .responseCompleted = $0 { return true }; return false }
        }
        #expect(await recognizer.beginCount >= 2)
    }

    @Test("Speech barge-in stops synthesis and yields the floor")
    func speechBargeIn() async throws {
        let synthGate = FakeGate(open: false)
        let synth = FakeSynthesizer(gate: synthGate)
        let (session, _, _, log, consumer) = try await makeSession(
            policy: RealtimeTurnPolicy(speakResponsesAloud: true),
            synthesizer: synth
        )
        defer { consumer.cancel() }
        try await session.start()
        try await session.sendText("talk")
        await waitUntil("synthesis started") { await synth.spoken.count == 1 }
        for _ in 0..<3 { try await session.ingestAudio(samples: speechChunk(), sampleRate: 16_000) }
        await waitUntil("speech interruption") {
            await log.contains { $0 == .interrupted(.userSpeech) }
        }
        #expect(await synth.stopCount >= 1)
        await synthGate.release()
    }

    @Test("Screen frames reach vision providers as attachments")
    func framesToVisionProvider() async throws {
        let (session, provider, _, log, consumer) = try await makeSession()
        defer { consumer.cancel() }
        try await session.start()
        try await session.ingestFrame(jpegFrame(source: .screen))
        try await session.ingestFrame(jpegFrame(source: .camera))
        await waitUntil("frames buffered") {
            await log.count { if case .frameBuffered = $0 { return true }; return false } == 2
        }
        try await session.sendText("what do you see")
        await waitUntil("vision reply") {
            await log.contains { if case .responseCompleted = $0 { return true }; return false }
        }
        let attachments = await provider.lastPrompt?.last?.attachments
        #expect(attachments?.count == 2)
        #expect(attachments?.map(\.kind).sorted() == ["camera", "screen"])
    }

    @Test("Non-vision providers get an honest descriptor instead of pixels")
    func framesWithoutVision() async throws {
        let (session, provider, _, log, consumer) = try await makeSession(
            capabilities: ModelCapabilities(
                supportsStreaming: true,
                supportsToolCalling: false,
                supportsVision: false,
                supportsJSONSchema: false,
                maxContextTokens: 4_096,
                isOnDevice: true
            )
        )
        defer { consumer.cancel() }
        try await session.start()
        try await session.ingestFrame(jpegFrame())
        try await session.sendText("describe")
        await waitUntil("descriptor reply") {
            await log.contains { if case .responseCompleted = $0 { return true }; return false }
        }
        let last = await provider.lastPrompt?.last
        #expect(last?.attachments == nil)
        #expect(last?.content.contains("no vision support") == true)
    }

    @Test("Frame buffer keeps newest-N and reports drops")
    func frameBufferBound() async throws {
        let (session, _, _, log, consumer) = try await makeSession(
            policy: RealtimeTurnPolicy(speakResponsesAloud: false, maxBufferedFrames: 2)
        )
        defer { consumer.cancel() }
        try await session.start()
        try await session.ingestFrame(jpegFrame())
        try await session.ingestFrame(jpegFrame())
        try await session.ingestFrame(jpegFrame())
        await waitUntil("drop reported") {
            await log.contains { if case .frameDropped = $0 { return true }; return false }
        }
    }

    @Test("Input bounds reject empty text, bad audio, and bad frames")
    func inputBounds() async throws {
        let (session, _, _, _, consumer) = try await makeSession()
        defer { consumer.cancel() }
        await #expect(throws: RealtimeError.self) { try await session.sendText("before start") }
        try await session.start()
        await #expect(throws: RealtimeError.self) { try await session.start() }
        await #expect(throws: RealtimeError.self) { try await session.sendText("   ") }
        await #expect(throws: RealtimeError.self) {
            try await session.ingestAudio(samples: speechChunk(), sampleRate: 44_100)
        }
        await #expect(throws: RealtimeError.self) {
            try await session.ingestAudio(samples: [Float](repeating: 0, count: 500_000), sampleRate: 16_000)
        }
        await #expect(throws: RealtimeError.self) {
            try await session.ingestFrame(RealtimeFrame(source: .image, mimeType: "image/gif", imageData: Data([1])))
        }
        await #expect(throws: RealtimeError.self) {
            try await session.ingestFrame(RealtimeFrame(source: .image, mimeType: "image/png", imageData: Data()))
        }
        await session.stop()
    }

    @Test("Live partials surface as transcription events")
    func livePartials() async throws {
        let recognizer = FakeRecognizer()
        let (session, _, _, log, consumer) = try await makeSession(recognizer: recognizer)
        defer { consumer.cancel() }
        try await session.start()
        await recognizer.emitPartial("hel")
        await waitUntil("partial surfaced") {
            await log.contains { $0 == .partialTranscript("hel") }
        }
    }

    @Test("OpenAI bodies encode attachments as image_url parts")
    func openAIAttachmentBody() throws {
        let plain = OpenAIProvider.messageContent(for: .user("hi"))
        #expect((plain as? String) == "hi")
        let attachment = MessageAttachment(kind: "screen", mimeType: "image/png", data: Data([1, 2, 3]))
        let mixed = OpenAIProvider.messageContent(for: ChatMessage(role: .user, content: "see", attachments: [attachment]))
        let parts = try #require(mixed as? [[String: Any]])
        #expect(parts.count == 2)
        #expect((parts[1]["type"] as? String) == "image_url")
        let url = try #require((parts[1]["image_url"] as? [String: String])?["url"])
        #expect(url.hasPrefix("data:image/png;base64,"))
        let body = try OpenAIProvider.requestBody(model: "m", prompt: [.user("hi")], tools: [], options: GenerationOptions(), stream: false)
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(decoded["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "hi")
    }

    @Test("Gemini parts encode attachments as inline_data")
    func geminiAttachmentParts() {
        let parts = GoogleGeminiProvider.messageParts(for: .user("hi"))
        #expect(parts.count == 1)
        let attachment = MessageAttachment(kind: "camera", mimeType: "image/jpeg", data: Data([9, 9]))
        let mixed = GoogleGeminiProvider.messageParts(
            for: ChatMessage(role: .user, content: "see", attachments: [attachment])
        )
        #expect(mixed.count == 2)
        let inline = (mixed[1]["inline_data"] as? [String: String])
        #expect(inline?["mime_type"] == "image/jpeg")
        #expect(inline?["data"] == Data([9, 9]).base64EncodedString())
    }
}
