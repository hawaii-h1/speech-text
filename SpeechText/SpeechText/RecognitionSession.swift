// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Speech

// MARK: - Protocol

/// What a session tells the engine while a segment is open. Always delivered on the main thread.
enum RecognitionEvent {
    /// The text so far. `committed` will not change again; `partial` may still be revised.
    /// Kept apart (rather than pre-joined) so a later span layer can map them onto
    /// partial / commit / revise without re-splitting a string.
    case live(committed: String, partial: String)
    /// The recogniser reported an error while the segment was open. Becomes
    /// `SpeechEngine.errorMessage`. Streaming sessions never send this: a broken stream
    /// is their own business (they fall back to the batch upload).
    case failure(String)
}

/// The result of a finished segment. History bookkeeping stays in the engine, so this
/// carries everything the engine needs to write the record.
struct RecognitionOutcome {
    /// Trimmed. Empty when nothing was recognised or the segment failed.
    var text: String
    /// Set when the segment failed. May coexist with non-empty text (Apple: an error after
    /// some words were recognised) — text wins for History, the error is still surfaced.
    var error: String?
    /// The segment file a batch session wrote. Ownership passes to the engine, which
    /// deletes it on success and hands it to History otherwise.
    var audioFileURL: URL?
    /// `cancel()` or task cancellation cut the wait short: nothing is recorded and the
    /// file, if any, is deleted.
    var cancelled: Bool

    static let cancelled = RecognitionOutcome(text: "", error: nil, audioFileURL: nil, cancelled: true)
}

/// One segment of recognition, whatever the tier. Created by `makeRecognitionSession`
/// once per segment (a resume is a new session); the engine owns the microphone, the
/// tap and the `AudioBufferWriter`, and the session gets the writer by reference.
protocol RecognitionSession: AnyObject {
    /// Set by the engine before `start()`. Invoked on the main thread.
    var onEvent: ((RecognitionEvent) -> Void)? { get set }
    /// Opens sockets / recognisers. Called before the tap is installed and before the
    /// audio engine starts, so a TLS handshake overlaps the hardware start.
    func start() throws
    /// One tap buffer, from the audio thread. `native` is the hardware-format buffer
    /// (Apple resamples itself); `pcm16` is the writer's 16 kHz mono Int16 conversion of
    /// the same buffer, nil on the writer's native-copy fallback path or on a converter error.
    func feed(native: AVAudioPCMBuffer, pcm16: Data?)
    /// The mic stopped feeding this segment (pause, or a stop about to `finish()`).
    /// Returns the segment's text when the session can hand it over at once (Apple's
    /// live text, no history entry), or nil when it must be waited for with `finish()`.
    /// Must be idempotent and synchronous on the main thread: the engine calls it before
    /// spawning the `finish()` task so no session-internal timer can fire in between.
    func pause() -> String?
    /// Commits what is pending and returns the segment's text once known. Bounded: Apple
    /// waits ≤ 0.5 s for `isFinal`, streaming ≤ `STTTuning.streamFinishTimeoutSeconds`
    /// then falls back, batch is bounded by the provider's URLSession timeouts.
    /// Called at most once per session.
    func finish() async -> RecognitionOutcome
    /// Drops everything immediately. Idempotent; safe after `finish()` returned.
    func cancel()
}

enum RecognitionSessionError: LocalizedError {
    case recognizerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let locale): return "Speech recognizer not available for \(locale)"
        }
    }
}

/// The one place that knows which tier a configuration selects. Streaming is a
/// composition: `StreamingRecognitionSession` wraps a `BatchRecognitionSession` and
/// hands over to it when the stream fails or returns nothing.
func makeRecognitionSession(configuration: RecordingConfiguration,
                            writer: AudioBufferWriter,
                            recognizer: SFSpeechRecognizer?) -> RecognitionSession {
    switch configuration.provider {
    case .apple:
        return AppleRecognitionSession(recognizer: recognizer, locale: configuration.locale)
    case .groq, .elevenlabs:
        let batch = BatchRecognitionSession(provider: makeBatchProvider(configuration: configuration),
                                            writer: writer, language: configuration.cloudLanguage)
        if let streamer = makeStreamingProvider(configuration: configuration) {
            return StreamingRecognitionSession(provider: streamer, writer: writer,
                                               language: configuration.cloudLanguage, fallback: batch)
        }
        return batch
    }
}
