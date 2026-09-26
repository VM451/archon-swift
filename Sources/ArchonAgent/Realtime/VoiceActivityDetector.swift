import Foundation

/// Turn-boundary events produced by the voice activity detector.
public enum VoiceActivityEvent: Sendable, Equatable {
    case speechStarted
    case speechEnded(utteranceMs: Int)
}

/// Deterministic energy-based voice activity detector over mono PCM chunks.
///
/// This is the local turn-taking primitive behind automatic pause handling:
/// callers feed fixed-size chunks with their durations and receive
/// speech-start/end boundaries. It performs no I/O, allocates nothing per
/// chunk beyond the event itself, and is safe to drive from realtime audio
/// callbacks as well as from tests.
public struct VoiceActivityDetector: Sendable {
    private let threshold: Float
    private let minSpeechMs: Int
    private let silenceHangoverMs: Int
    private let maxUtteranceMs: Int

    private var speechStreak = 0
    private var silenceStreak = 0
    private var inSpeech = false
    private var utteranceChunks = 0

    /// - Parameters:
    ///   - policy: Turn policy supplying threshold and timing.
    ///   - chunkMs: Nominal duration in milliseconds of each ingested chunk.
    ///     The actual per-call `chunkMs` always wins; this is only a hint.
    public init(policy: RealtimeTurnPolicy, chunkMs: Int = 100) {
        self.threshold = policy.vadEnergyThreshold
        self.minSpeechMs = policy.minSpeechMs
        self.silenceHangoverMs = policy.silenceHangoverMs
        self.maxUtteranceMs = policy.maxUtteranceSeconds * 1_000
        _ = chunkMs
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in samples {
            energy += sample * sample
        }
        return (energy / Float(samples.count)).squareRoot()
    }

    /// Ingests one chunk and returns a boundary event when the turn state flips.
    /// Timing always derives from this call's `chunkMs`, so hosts may vary
    /// chunk sizes without skewing turn boundaries.
    public mutating func ingest(samples: [Float], chunkMs: Int) -> VoiceActivityEvent? {
        let step = max(10, chunkMs)
        let speechNeeded = max(1, (minSpeechMs + step - 1) / step)
        let silenceNeeded = max(1, (silenceHangoverMs + step - 1) / step)
        let maxChunks = max(1, maxUtteranceMs / step)
        let energy = Self.rms(samples)
        if energy >= threshold {
            speechStreak += 1
            silenceStreak = 0
            if !inSpeech && speechStreak >= speechNeeded {
                inSpeech = true
                utteranceChunks = 0
                return .speechStarted
            }
            if inSpeech {
                utteranceChunks += 1
                if utteranceChunks >= maxChunks {
                    inSpeech = false
                    speechStreak = 0
                    return .speechEnded(utteranceMs: utteranceChunks * step)
                }
            }
            return nil
        }
        silenceStreak += 1
        speechStreak = 0
        if inSpeech && silenceStreak >= silenceNeeded {
            inSpeech = false
            let ended = VoiceActivityEvent.speechEnded(utteranceMs: utteranceChunks * step)
            utteranceChunks = 0
            return ended
        }
        return nil
    }

    public var isInSpeech: Bool { inSpeech }
}
