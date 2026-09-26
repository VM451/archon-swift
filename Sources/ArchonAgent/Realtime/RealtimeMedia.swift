import Foundation

/// Typed failures for the realtime interactive-agent boundary.
public enum RealtimeError: Error, LocalizedError, Sendable, Equatable {
    case sessionNotStarted
    case sessionAlreadyStarted
    case invalidPolicy(reason: String)
    case inputRejected(reason: String)
    case speechUnavailable(reason: String)
    case generationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotStarted:
            return "Realtime session is not started."
        case .sessionAlreadyStarted:
            return "Realtime session is already started."
        case .invalidPolicy(let reason):
            return "Invalid realtime turn policy: \(reason)"
        case .inputRejected(let reason):
            return "Realtime input rejected: \(reason)"
        case .speechUnavailable(let reason):
            return "Speech capability unavailable: \(reason)"
        case .generationFailed(let reason):
            return "Realtime generation failed: \(reason)"
        }
    }
}

/// Source of a visual frame delivered to a realtime session.
public enum RealtimeFrameSource: String, Sendable, Codable, Equatable {
    case camera
    case screen
    case image
}

/// A bounded visual frame (camera, screen share, or still image) supplied by
/// the host app. The package never captures media itself: microphone, camera,
/// and screen-capture permissions, entitlements, and capturers remain
/// host-owned. Frames arrive here as already-encoded JPEG/PNG bytes.
public struct RealtimeFrame: Sendable, Codable, Equatable, Identifiable {
    public static let maximumBytes = 8 * 1024 * 1024

    public let id: String
    public let source: RealtimeFrameSource
    public let mimeType: String
    public let imageData: Data
    public let capturedAt: Date

    public init(
        id: String = UUID().uuidString,
        source: RealtimeFrameSource,
        mimeType: String,
        imageData: Data,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.mimeType = mimeType
        self.imageData = imageData
        self.capturedAt = capturedAt
    }

    func validated() throws -> RealtimeFrame {
        guard !imageData.isEmpty else {
            throw RealtimeError.inputRejected(reason: "Frame carries no image bytes.")
        }
        guard imageData.count <= Self.maximumBytes else {
            throw RealtimeError.inputRejected(reason: "Frame exceeds the 8 MB bound.")
        }
        guard mimeType == "image/jpeg" || mimeType == "image/png" else {
            throw RealtimeError.inputRejected(reason: "Frame must be image/jpeg or image/png.")
        }
        return self
    }

    func asAttachment() -> MessageAttachment {
        MessageAttachment(kind: source.rawValue, mimeType: mimeType, data: imageData, capturedAt: capturedAt)
    }
}

/// One input delivered to a realtime session. Text, audio, and visual frames
/// share one timeline so the user can type while speaking, speak while the
/// agent talks, and stream screen/camera frames at any moment.
public enum RealtimeInput: Sendable, Equatable {
    case text(String)
    case audio(samples: [Float], sampleRate: Int)
    case frame(RealtimeFrame)
}

enum RealtimeInputPolicy {
    static let maximumTextBytes = 32 * 1024
    static let maximumAudioSamples = 480_000
    static let supportedSampleRates: Set<Int> = [8_000, 16_000, 24_000, 48_000]

    static func validatedText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeError.inputRejected(reason: "Text input is empty.")
        }
        guard trimmed.utf8.count <= maximumTextBytes else {
            throw RealtimeError.inputRejected(reason: "Text input exceeds the 32 KB bound.")
        }
        return trimmed
    }

    static func validatedAudio(samples: [Float], sampleRate: Int) throws -> [Float] {
        guard supportedSampleRates.contains(sampleRate) else {
            throw RealtimeError.inputRejected(reason: "Unsupported audio sample rate.")
        }
        guard !samples.isEmpty else {
            throw RealtimeError.inputRejected(reason: "Audio input carries no samples.")
        }
        guard samples.count <= maximumAudioSamples else {
            throw RealtimeError.inputRejected(reason: "Audio input exceeds the 10 s bound at 48 kHz.")
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw RealtimeError.inputRejected(reason: "Audio samples must be finite mono PCM in -1...1.")
        }
        return samples
    }
}
