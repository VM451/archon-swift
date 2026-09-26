# Realtime voice + vision agent

`RealtimeSession` (`ArchonAgent`) is the Archon-owned orchestration for
Gemini Live / GPT-Live style interaction: full-duplex voice with barge-in,
live transcription of both sides, text sent at any moment (even while the
agent talks), and camera/screen frames streamed alongside audio.

## What the package owns

- Turn-taking: `RealtimeTurnPolicy` (VAD threshold, pause tolerance,
  utterance cap, barge-in switch) plus a deterministic energy-based
  `VoiceActivityDetector`. No push-to-talk needed.
- Full-duplex session: `RealtimeSession` merges microphone PCM, text, and
  visual frames on one timeline, streams generation through any
  `LLMProvider`, speaks replies through any `SpeechSynthesizer`, and yields
  the floor on interruption with a turn-epoch guard so stale tasks can never
  emit after the floor changed hands.
- Speech seams: `StreamingSpeechRecognizer` / `SpeechSynthesizer` protocols
  with bundled Apple adapters (`AppleSpeechRecognizer` on-device
  `SFSpeechRecognizer`, `AppleSpeechSynthesizer` `AVSpeechSynthesizer` with
  immediate-stop barge-in).
- Vision wire: `MessageAttachment` on `ChatMessage`, mapped to OpenAI
  `image_url` parts and Gemini `inline_data` parts. Vision-capable providers
  receive pixels; others get an honest descriptor and no pixels are sent.

## What the host app owns

Microphone, camera, and screen-capture permission, entitlements, Info.plist
usage descriptions, audio-session configuration, and the capturers
(`AVAudioEngine`, `AVCaptureSession`, ScreenCaptureKit/ReplayKit). The
package never captures media itself; it accepts already-captured PCM samples
and JPEG/PNG frame bytes. API keys for cloud providers stay host-supplied,
and realtime model transports (OpenAI Realtime, Gemini Live, LiveKit-backed)
sit behind explicit host-owned adapters, never inside the core session.

## Minimal wiring

```swift
import ArchonAgent

let session = try await RealtimeSession(
    provider: myProvider,              // any LLMProvider; vision-capable for pixels
    recognizer: AppleSpeechRecognizer(),
    synthesizer: AppleSpeechSynthesizer(),
    policy: RealtimeTurnPolicy(vadEnergyThreshold: 0.08, silenceHangoverMs: 700),
    systemPrompt: "You are a concise voice assistant."
)

let consumer = Task {
    for await event in session.events {
        switch event {
        case .partialTranscript(let text): showLiveCaption(text)
        case .finalTranscript(let text): showUserTurn(text)
        case .responseChunk(let delta): appendAgentCaption(delta)
        case .responseCompleted(let text, let interrupted): finishAgentTurn(text, interrupted: interrupted)
        case .interrupted(let reason): showYielded(reason)
        case .stateChanged(let state): showState(state) // listening / thinking / speaking
        case .frameBuffered(let source, let count): showFrameBadge(source, count)
        case .frameDropped(let reason): logDroppedFrame(reason)
        case .speechStarted: showUserSpeaking()
        }
    }
}

try await session.start()

// Microphone tap (host-owned AVAudioEngine, 16 kHz mono Float PCM):
try await session.ingestAudio(samples: pcmSamples, sampleRate: 16_000)

// User types while the agent talks: latest input always wins.
try await session.sendText("actually, summarize instead")

// Camera / screen share (host-owned capturers, JPEG/PNG bytes):
try await session.ingestFrame(RealtimeFrame(source: .screen, mimeType: "image/jpeg", imageData: jpeg))

// Shutdown:
await session.stop()
consumer.cancel()
```

## Tuning barge-in vs patience

- Cutting the user off: raise `vadEnergyThreshold` or `minSpeechMs`.
- Slow to yield: lower `silenceHangoverMs`; keep `bargeInEnabled` true.
- Long monologues: lower `maxUtteranceSeconds` to force turn boundaries.
- Screen-heavy sessions: raise `maxBufferedFrames` (1...16); the buffer
  keeps newest-N and reports drops instead of growing memory.

## Verification boundary

Package tests (`RealtimeSessionTests`, 14 tests) prove turn-taking,
barge-in epoch guards, frame buffering, bounds, and both vision wire
mappings with deterministic fakes. Real microphone latency, on-device
recognition accuracy, spoken-voice quality, and camera/screen behavior
require a signed consuming app on physical hardware.
