import Foundation

/// One transcription delta from a streaming recognizer.
public struct PartialTranscript: Sendable, Codable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Vendor-neutral streaming speech-recognition seam.
///
/// The host app owns microphone permission, audio-session configuration, and
/// the capturer; it pushes already-captured mono PCM chunks here. The bundled
/// Apple adapter maps those chunks onto `SFSpeechRecognizer` with on-device
/// recognition. WhisperKit-style adapters can conform without touching the
/// session.
public protocol StreamingSpeechRecognizer: Sendable {
    var id: String { get }
    var supportsOnDevice: Bool { get }
    func begin() async throws -> AsyncThrowingStream<PartialTranscript, Error>
    func append(samples: [Float], sampleRate: Int) async throws
    func end() async throws -> PartialTranscript?
}

/// Vendor-neutral speech-synthesis seam for spoken responses and barge-in.
public protocol SpeechSynthesizer: Sendable {
    var id: String { get }
    func speak(text: String) async throws
    func stop() async
    var isSpeaking: Bool { get async }
}

#if canImport(AVFoundation)
import AVFoundation

/// `AVSpeechSynthesizer`-backed speech output with immediate-stop barge-in.
public final class AppleSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    public let id = "apple-avspeech"

    private let synthesizer = AVSpeechSynthesizer()
    private let state = SpeechDelegateState()

    public init() {
        synthesizer.delegate = state
    }

    public func speak(text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let utterance = AVSpeechUtterance(string: String(trimmed.prefix(4_096)))
                state.register(utterance: utterance, continuation: continuation)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    public func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
    }

    public var isSpeaking: Bool {
        get async { synthesizer.isSpeaking }
    }
}

private final class SpeechDelegateState: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var utterances: [ObjectIdentifier: AVSpeechUtterance] = [:]

    func register(utterance: AVSpeechUtterance, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock {
            continuations[ObjectIdentifier(utterance)] = continuation
            utterances[ObjectIdentifier(utterance)] = utterance
        }
    }

    private func finish(utterance: AVSpeechUtterance, error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let key = ObjectIdentifier(utterance)
            let stored = continuations.removeValue(forKey: key)
            utterances.removeValue(forKey: key)
            return stored
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance: utterance, error: nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance: utterance, error: CancellationError())
    }
}
#endif

#if canImport(Speech)
import Speech

/// `SFSpeechRecognizer`-backed streaming transcription with on-device policy.
///
/// Requires the host app to hold Speech/microphone authorization and the
/// matching Info.plist usage descriptions; otherwise `begin()` fails closed
/// with `RealtimeError.speechUnavailable`.
public final class AppleSpeechRecognizer: StreamingSpeechRecognizer, @unchecked Sendable {
    public let id = "apple-speech"
    public let supportsOnDevice: Bool

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let finalText = RecognizerFinalText()

    public init(locale: Locale = Locale.current) {
        let scoped = SFSpeechRecognizer(locale: locale)
        recognizer = scoped
        supportsOnDevice = scoped?.supportsOnDeviceRecognition ?? false
    }

    public func begin() async throws -> AsyncThrowingStream<PartialTranscript, Error> {
        let recognizer = lock.withLock { self.recognizer }
        let alreadyRunning = lock.withLock { request != nil }
        guard !alreadyRunning else {
            throw RealtimeError.sessionAlreadyStarted
        }
        guard let recognizer, recognizer.isAvailable else {
            throw RealtimeError.speechUnavailable(reason: "No Apple speech recognizer is available.")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw RealtimeError.speechUnavailable(reason: "Speech recognition is not authorized by the host app.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw RealtimeError.speechUnavailable(reason: "On-device recognition is unsupported on this device.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let finalText = self.finalText
        let (stream, continuation) = AsyncThrowingStream<PartialTranscript, Error>.makeStream()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            guard let result else { return }
            let transcript = PartialTranscript(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
            if result.isFinal {
                finalText.store(transcript.text)
                continuation.yield(transcript)
                continuation.finish()
            } else {
                continuation.yield(transcript)
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
        return stream
    }

    public func append(samples: [Float], sampleRate: Int) async throws {
        let request = lock.withLock { self.request }
        guard let request else { throw RealtimeError.sessionNotStarted }
        let validated = try RealtimeInputPolicy.validatedAudio(samples: samples, sampleRate: sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw RealtimeError.inputRejected(reason: "Could not describe the audio format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(validated.count)) else {
            throw RealtimeError.inputRejected(reason: "Could not allocate the audio buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(validated.count)
        validated.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData?.pointee.update(from: pointer.baseAddress!, count: validated.count)
        }
        request.append(buffer)
    }

    public func end() async throws -> PartialTranscript? {
        let (request, task) = lock.withLock { (self.request, self.task) }
        request?.endAudio()
        task?.finish()
        lock.withLock {
            self.request = nil
            self.task = nil
        }
        let text = finalText.take()
        guard !text.isEmpty else { return nil }
        return PartialTranscript(text: text, isFinal: true)
    }
}

private final class RecognizerFinalText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func store(_ value: String) {
        lock.withLock { text = value }
    }

    func take() -> String {
        lock.withLock {
            let value = text
            text = ""
            return value
        }
    }
}
#endif
