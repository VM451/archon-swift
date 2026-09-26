import Foundation

/// Turn-taking and interruption policy for a realtime session.
///
/// Mirrors the session-config surface of the OpenAI Realtime API (VAD
/// threshold, silence handling) and Gemini Live API (responsiveness) as an
/// Archon-owned value type, so hosts get one policy regardless of which
/// speech/model adapter sits behind the session.
public struct RealtimeTurnPolicy: Sendable, Codable, Equatable {
    /// Audio sample rate the session expects for PCM ingest.
    public var sampleRate: Int
    /// RMS energy in 0...1 above which a chunk counts as speech.
    public var vadEnergyThreshold: Float
    /// Milliseconds of speech required before a turn starts.
    public var minSpeechMs: Int
    /// Milliseconds of silence required before a turn ends.
    public var silenceHangoverMs: Int
    /// Hard cap on one spoken utterance before the turn is force-closed.
    public var maxUtteranceSeconds: Int
    /// When true, user speech or text while the agent is responding cancels
    /// the response and yields the floor, like Gemini Live / GPT-Live barge-in.
    public var bargeInEnabled: Bool
    /// When true the session speaks completed responses through the
    /// configured synthesizer as well as emitting response text.
    public var speakResponsesAloud: Bool
    /// Newest-N visual frames kept for the next model turn.
    public var maxBufferedFrames: Int

    public init(
        sampleRate: Int = 16_000,
        vadEnergyThreshold: Float = 0.08,
        minSpeechMs: Int = 240,
        silenceHangoverMs: Int = 700,
        maxUtteranceSeconds: Int = 30,
        bargeInEnabled: Bool = true,
        speakResponsesAloud: Bool = true,
        maxBufferedFrames: Int = 4
    ) {
        self.sampleRate = sampleRate
        self.vadEnergyThreshold = vadEnergyThreshold
        self.minSpeechMs = minSpeechMs
        self.silenceHangoverMs = silenceHangoverMs
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.bargeInEnabled = bargeInEnabled
        self.speakResponsesAloud = speakResponsesAloud
        self.maxBufferedFrames = maxBufferedFrames
    }

    public func validated() throws -> RealtimeTurnPolicy {
        guard RealtimeInputPolicy.supportedSampleRates.contains(sampleRate) else {
            throw RealtimeError.invalidPolicy(reason: "Unsupported sample rate.")
        }
        guard vadEnergyThreshold.isFinite && vadEnergyThreshold > 0 && vadEnergyThreshold < 1 else {
            throw RealtimeError.invalidPolicy(reason: "VAD threshold must be within 0...1 exclusive.")
        }
        guard minSpeechMs >= 60 && minSpeechMs <= 5_000 else {
            throw RealtimeError.invalidPolicy(reason: "minSpeechMs must be within 60...5000.")
        }
        guard silenceHangoverMs >= 100 && silenceHangoverMs <= 10_000 else {
            throw RealtimeError.invalidPolicy(reason: "silenceHangoverMs must be within 100...10000.")
        }
        guard maxUtteranceSeconds >= 2 && maxUtteranceSeconds <= 180 else {
            throw RealtimeError.invalidPolicy(reason: "maxUtteranceSeconds must be within 2...180.")
        }
        guard maxBufferedFrames >= 1 && maxBufferedFrames <= 16 else {
            throw RealtimeError.invalidPolicy(reason: "maxBufferedFrames must be within 1...16.")
        }
        return self
    }
}
