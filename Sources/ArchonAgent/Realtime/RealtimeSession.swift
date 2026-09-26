import Foundation

/// Lifecycle state of a realtime session.
public enum RealtimeSessionState: String, Sendable, Codable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

/// Why the agent yielded the floor.
public enum RealtimeInterruptionReason: String, Sendable, Codable, Equatable {
    case userSpeech
    case userText
    case stopped
}

/// Events emitted by a realtime session, covering both sides of the
/// conversation: user speech boundaries and live transcription plus agent
/// response chunks, speech state, interruptions, and visual-frame handling.
public enum RealtimeEvent: Sendable, Equatable {
    case stateChanged(RealtimeSessionState)
    case speechStarted
    case partialTranscript(String)
    case finalTranscript(String)
    case responseChunk(String)
    case responseCompleted(String, interrupted: Bool)
    case interrupted(RealtimeInterruptionReason)
    case frameBuffered(source: RealtimeFrameSource, buffered: Int)
    case frameDropped(reason: String)
}

/// Full-duplex interactive agent session: simultaneous voice, text, and
/// visual input with barge-in, live transcription, and spoken responses.
///
/// This is the Archon-owned orchestration behind Gemini Live / GPT-Live style
/// dynamics: the user can speak over the agent, type while it talks, and
/// stream camera/screen frames at any moment. Speech recognition, speech
/// synthesis, and language generation stay behind vendor-neutral seams, so the
/// same session runs on Apple on-device adapters today and on realtime model
/// transports (OpenAI Realtime, Gemini Live, LiveKit-backed) behind explicit
/// host-owned adapters tomorrow.
public actor RealtimeSession {
    private static let maximumHistoryMessages = 100

    private let provider: any LLMProvider
    private let recognizer: any StreamingSpeechRecognizer
    private let synthesizer: (any SpeechSynthesizer)?
    private let policy: RealtimeTurnPolicy
    private let tools: [ToolDefinition]
    private let options: GenerationOptions
    private let systemPrompt: String?

    private var state: RealtimeSessionState = .idle
    private var history: [ChatMessage] = []
    private var frames: [RealtimeFrame] = []
    private var vad: VoiceActivityDetector
    private var recognitionStream: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var started = false
    /// Monotonic turn counter. Barge-in and new turns invalidate in-flight
    /// completions so a stale task can never emit or move state after the
    /// floor changed hands.
    private var turnEpoch = 0

    private let eventsContinuation: AsyncStream<RealtimeEvent>.Continuation
    public nonisolated let events: AsyncStream<RealtimeEvent>

    public init(
        provider: any LLMProvider,
        recognizer: any StreamingSpeechRecognizer,
        synthesizer: (any SpeechSynthesizer)? = nil,
        policy: RealtimeTurnPolicy = RealtimeTurnPolicy(),
        tools: [ToolDefinition] = [],
        options: GenerationOptions = GenerationOptions(),
        systemPrompt: String? = nil
    ) throws {
        self.provider = provider
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.policy = try policy.validated()
        self.tools = tools
        self.options = options
        self.systemPrompt = systemPrompt
        self.vad = VoiceActivityDetector(policy: policy, chunkMs: 100)
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !started else { throw RealtimeError.sessionAlreadyStarted }
        started = true
        if let systemPrompt {
            history.append(.system(systemPrompt))
        }
        try await beginRecognitionForwarding()
        setState(.listening)
    }

    public func stop() async {
        recognitionStream?.cancel()
        recognitionStream = nil
        await interruptActiveResponse(reason: .stopped, emitEvent: false)
        try? await recognizer.end()
        frames.removeAll()
        started = false
        setState(.idle)
    }

    // MARK: - Input

    /// Sends text at any moment, including while the agent is responding.
    /// The latest user input always wins: an in-flight response is cancelled
    /// first so the reply answers the new message.
    public func sendText(_ text: String) async throws {
        guard started else { throw RealtimeError.sessionNotStarted }
        let clean = try RealtimeInputPolicy.validatedText(text)
        await interruptActiveResponse(reason: .userText, emitEvent: true)
        appendHistory(.user(clean))
        startGeneration(for: clean)
    }

    /// Ingests one mono PCM chunk. Drives VAD turn boundaries, forwards audio
    /// to the recognizer, and triggers barge-in when the user speaks over the
    /// agent.
    public func ingestAudio(samples: [Float], sampleRate: Int) async throws {
        guard started else { throw RealtimeError.sessionNotStarted }
        let pcm = try RealtimeInputPolicy.validatedAudio(samples: samples, sampleRate: sampleRate)
        try await recognizer.append(samples: pcm, sampleRate: sampleRate)
        let chunkMs = max(10, (pcm.count * 1_000) / max(1, sampleRate))
        if let boundary = vad.ingest(samples: pcm, chunkMs: chunkMs) {
            switch boundary {
            case .speechStarted:
                emit(.speechStarted)
                if policy.bargeInEnabled {
                    await interruptActiveResponse(reason: .userSpeech, emitEvent: true)
                }
            case .speechEnded:
                await finishSpokenTurn()
            }
        }
    }

    /// Buffers one camera/screen/image frame for the next model turn.
    /// Keeps newest-N per policy; the oldest frame is dropped with an event.
    public func ingestFrame(_ frame: RealtimeFrame) async throws {
        guard started else { throw RealtimeError.sessionNotStarted }
        let valid = try frame.validated()
        frames.append(valid)
        while frames.count > policy.maxBufferedFrames {
            frames.removeFirst()
            emit(.frameDropped(reason: "Frame buffer keeps newest-\(policy.maxBufferedFrames)."))
        }
        emit(.frameBuffered(source: valid.source, buffered: frames.count))
    }

    public func transcript() -> [ChatMessage] { history }

    // MARK: - Private

    private func handleRecognizerPartial(_ partial: PartialTranscript) {
        if partial.isFinal {
            emit(.finalTranscript(partial.text))
        } else {
            emit(.partialTranscript(partial.text))
        }
    }

    private func finishSpokenTurn() async {
        guard let final = try? await recognizer.end(), !final.text.isEmpty else {
            // No transcript: re-arm recognition so the next utterance is heard.
            try? await beginRecognitionForwarding()
            return
        }
        emit(.finalTranscript(final.text))
        appendHistory(.user(final.text))
        // The ended recognition task cannot accept more audio; re-arm first so
        // the user can barge in over the coming response without a gap.
        try? await beginRecognitionForwarding()
        startGeneration(for: final.text)
    }

    /// (Re)arms recognizer forwarding. Called at start and after every spoken
    /// turn because an ended recognition request cannot accept more audio.
    private func beginRecognitionForwarding() async throws {
        recognitionStream?.cancel()
        recognitionStream = nil
        let stream = try await recognizer.begin()
        recognitionStream = Task { [weak self] in
            do {
                for try await partial in stream {
                    await self?.handleRecognizerPartial(partial)
                }
            } catch {
                self?.emit(.frameDropped(reason: "Recognizer stream ended: \(error.localizedDescription)"))
            }
        }
    }

    private func startGeneration(for userText: String) {
        generationTask?.cancel()
        turnEpoch += 1
        let epoch = turnEpoch
        let prompt = buildPrompt(userText: userText)
        setState(.thinking)
        generationTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = await self.providerStream(prompt: prompt)
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    guard await self.isCurrent(epoch: epoch) else { break }
                    if let delta = chunk.deltaText, !delta.isEmpty {
                        accumulated += delta
                        await self.emit(.responseChunk(delta))
                    }
                    if chunk.isFinished { break }
                }
            } catch is CancellationError {
                // Barge-in path below commits whatever arrived so far.
            } catch {
                if await self.isCurrent(epoch: epoch) {
                    await self.emit(.frameDropped(reason: "Generation failed: \(error.localizedDescription)"))
                }
            }
            await self.completeResponse(accumulated, interrupted: Task.isCancelled, epoch: epoch)
        }
    }

    private func providerStream(prompt: [ChatMessage]) async -> AsyncThrowingStream<ModelResponseChunk, Error> {
        provider.stream(prompt: prompt, tools: tools, options: options)
    }

    private func isCurrent(epoch: Int) -> Bool { epoch == turnEpoch }

    private func completeResponse(_ text: String, interrupted: Bool, epoch: Int) async {
        guard epoch == turnEpoch else { return }
        generationTask = nil
        if !text.isEmpty {
            appendHistory(.assistant(text))
        }
        emit(.responseCompleted(text, interrupted: interrupted))
        guard !interrupted, policy.speakResponsesAloud, !text.isEmpty else {
            if !interrupted { setState(.listening) }
            return
        }
        setState(.speaking)
        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synthesizer?.speak(text: text)
            } catch is CancellationError {
                // Yielded the floor; state is set by the interrupter.
            } catch {
                if await self.isCurrent(epoch: epoch) {
                    await self.emit(.frameDropped(reason: "Speech synthesis failed: \(error.localizedDescription)"))
                }
            }
            await self.speakingFinished(epoch: epoch)
        }
    }

    private func speakingFinished(epoch: Int) async {
        guard epoch == turnEpoch else { return }
        speakTask = nil
        if state == .speaking {
            setState(.listening)
        }
    }

    private func interruptActiveResponse(reason: RealtimeInterruptionReason, emitEvent: Bool) async {
        let hadWork = generationTask != nil || speakTask != nil || state == .speaking || state == .thinking
        turnEpoch += 1
        generationTask?.cancel()
        generationTask = nil
        speakTask?.cancel()
        speakTask = nil
        await synthesizer?.stop()
        if hadWork {
            if emitEvent { emit(.interrupted(reason)) }
            setState(.listening)
        }
    }

    private func buildPrompt(userText: String) -> [ChatMessage] {
        var prompt = history
        guard !frames.isEmpty else { return prompt }
        let attachments = frames.map { $0.asAttachment() }
        frames.removeAll()
        guard let last = prompt.popLast() else { return prompt }
        if provider.capabilities.supportsVision {
            prompt.append(ChatMessage(
                role: last.role,
                content: last.content,
                toolCalls: last.toolCalls,
                toolCallId: last.toolCallId,
                attachments: attachments,
                timestamp: last.timestamp
            ))
        } else {
            let kinds = attachments.map(\.kind).joined(separator: ", ")
            prompt.append(ChatMessage(
                role: last.role,
                content: last.content + "\n[\(attachments.count) visual frame(s) captured (\(kinds)); this provider has no vision support so pixels were not sent]",
                toolCalls: last.toolCalls,
                toolCallId: last.toolCallId,
                timestamp: last.timestamp
            ))
        }
        return prompt
    }

    private func appendHistory(_ message: ChatMessage) {
        history.append(message)
        if history.count > Self.maximumHistoryMessages {
            let system = history.first.flatMap { $0.role == .system ? $0 : nil }
            let tail = history.suffix(Self.maximumHistoryMessages - (system == nil ? 0 : 1))
            history = (system.map { [$0] } ?? []) + Array(tail)
        }
    }

    private func setState(_ next: RealtimeSessionState) {
        if state != next {
            state = next
            emit(.stateChanged(next))
        }
    }

    /// Thread-safe: the continuation supports concurrent yields, so detached
    /// forwarding tasks can emit without hopping onto the actor.
    private nonisolated func emit(_ event: RealtimeEvent) {
        eventsContinuation.yield(event)
    }
}
