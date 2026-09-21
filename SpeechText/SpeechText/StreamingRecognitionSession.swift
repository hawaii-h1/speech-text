// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Streaming with batch fallback

/// Pushes the tap's audio over the realtime socket — the writer's own 16 kHz bytes when
/// the provider wants that rate, a converted copy of the native buffer when it wants
/// another — and mirrors its events into committed / partial text. When the stream
/// breaks or ends with nothing, `finish()` hands the segment to the wrapped batch
/// session, which uploads the same writer's file.
final class StreamingRecognitionSession: RecognitionSession {
    var onEvent: ((RecognitionEvent) -> Void)?

    private let provider: StreamingSTTProvider
    private let writer: AudioBufferWriter
    /// nil leaves the language to the model — see `RecordingConfiguration.cloudLanguage`.
    private let language: String?
    /// A `BatchRecognitionSession` over the same writer in the app. Typed by the protocol
    /// so a replay can stand in the upload's answer without a network or an audio file.
    private let fallback: RecognitionSession

    // Main-thread state.
    private var committedText = "" {
        didSet { committedWords = transcriptWords(committedText) }
    }
    /// `committedText` tokenised once per commit rather than once per partial — the
    /// partial arrives several times a second and is merged against all of it each time.
    private var committedWords: [TranscriptWord] = []
    private var partialText = ""
    /// Set when the stream broke; `finish()` then falls back to the batch upload.
    private var failure: String?
    private var connected = false
    private var eventsTask: Task<Void, Never>?
    /// Read from the audio thread; cleared on main once a failure is known so no audio
    /// is pushed into a stream that will be discarded.
    private var sendEnabled = true

    // Audio-thread state. `feed` is the only thing that touches these, and the tap
    // calls it serially, so they need no lock.
    //
    // A provider whose socket wants a rate other than the writer's owns a converter of
    // its own, fed from the *native* tap buffer rather than from the writer's output:
    // 48 kHz → 24 kHz in one step is both cheaper and cleaner than 48 → 16 → 24. This is
    // what `StreamingSTTProvider.sampleRate` was declared for ("the engine converts the
    // mic feed to it"); before OpenAI's realtime tier, every provider happened to want
    // the writer's 16 kHz and the mismatch simply skipped the stream.
    private let needsResampling: Bool
    private var resampler: PCMDownsampler?
    /// The format `resampler` was built for. A device change hands the tap a new one
    /// mid-recording (see `SpeechEngine.restartAudioEngine`), and the converter cannot
    /// be re-pointed, so it is rebuilt — losing only the handful of frames in its delay
    /// line, at a boundary where the hardware just changed anyway.
    ///
    /// Compared with `!=`, which on an `AVAudioFormat` is `isEqual:` and not object
    /// identity (`AVAudioFormatEqualityTests` pins that down): the tap hands out a fresh
    /// instance per buffer, so an identity test would rebuild the converter fifty times
    /// a second and throw away its delay line each time.
    private var resamplerFormat: AVAudioFormat?

    init(provider: StreamingSTTProvider, writer: AudioBufferWriter, language: String?,
         fallback: RecognitionSession) {
        self.needsResampling = provider.sampleRate != AudioBufferWriter.uploadSampleRate
        self.provider = provider
        self.writer = writer
        self.language = language
        self.fallback = fallback
    }

    func start() throws {
        connected = true
        provider.connect(language: language)
        let provider = self.provider
        eventsTask = Task { [weak self] in
            for await event in provider.events {
                await MainActor.run { self?.handle(event) }
            }
        }
    }

    private func handle(_ event: StreamingSTTEvent) {
        switch event {
        case .partial(let text): DictationTraceRecorder.record(.partial, text: text)
        case .committed(let text): DictationTraceRecorder.record(.committed, text: text)
        case .failed(let error): DictationTraceRecorder.record(.streamFailed, error: error.localizedDescription)
        }
        switch event {
        case .partial(let text):
            // The stream re-states what it has already committed — sometimes verbatim,
            // sometimes grown by the words said since — so the partial is reduced to
            // what it actually adds. Joining it whole pastes the dictation twice.
            partialText = transcriptContinuation(of: committedText, committedWords: committedWords, in: text)
        case .committed(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Merged, not appended: a commit that restates the whole accumulated
                // transcript replaces what we hold rather than doubling it, and its
                // version of the overlapping words wins — it was made with more audio.
                committedText = mergedTranscript(committedText, trimmed)
            }
            partialText = ""
        case .failed(let error):
            failure = error.localizedDescription
            sendEnabled = false
        }
        onEvent?(.live(committed: committedText, partial: partialText))
    }

    private func markFailed(_ message: String) {
        guard failure == nil else { return }
        failure = message
        sendEnabled = false
    }

    func feed(native: AVAudioPCMBuffer, pcm16: Data?) {
        guard sendEnabled else { return }
        if needsResampling {
            // The writer's bytes are the wrong rate for this socket, so the stream does
            // not depend on the writer converting at all — only on this converter.
            guard let converted = resampled(native) else {
                DispatchQueue.main.async {
                    guard self.failure == nil else { return }
                    dlog("Engine", "stream: cannot convert \(native.format.sampleRate) Hz to \(self.provider.sampleRate) Hz — stream discarded, batch fallback at stop")
                    self.markFailed("Could not convert audio for streaming")
                }
                return
            }
            if !converted.isEmpty { provider.send(pcm16: converted) }
            return
        }
        if let pcm16 {
            provider.send(pcm16: pcm16)
        } else if !writer.isConvertingLive {
            // No live converter (or it died mid-session). The writer keeps the audio
            // natively, but the stream can no longer be fed, so the stop must upload the file.
            DispatchQueue.main.async {
                guard self.failure == nil else { return }
                dlog("Engine", "stream: live conversion unavailable — stream will be discarded, batch fallback at stop")
                self.markFailed("Could not convert audio for streaming")
            }
        }
    }

    /// One tap buffer at the provider's rate. Returns an empty `Data` while the
    /// converter primes (it has taken the audio and not emitted any yet), and nil only
    /// when no converter can be made for this hardware format.
    private func resampled(_ buffer: AVAudioPCMBuffer) -> Data? {
        if resampler == nil || resamplerFormat != buffer.format {
            resampler = PCMDownsampler(sourceFormat: buffer.format, targetRate: provider.sampleRate)
            resamplerFormat = resampler == nil ? nil : buffer.format
            if resampler != nil {
                dlog("Engine", "stream: converting \(buffer.format.sampleRate) Hz tap to \(provider.sampleRate) Hz")
            }
        }
        guard let resampler else { return nil }
        return resampler.convert(buffer)
    }

    func pause() -> String? { nil }

    func finish() async -> RecognitionOutcome {
        // Snapshot both under main-actor isolation: `cancel()` nils `eventsTask` on
        // main, and this function runs off it.
        let (connected, events) = await MainActor.run { (self.connected, self.eventsTask) }
        if connected {
            await provider.finish()
            // `finish()` closes the event stream, so draining the mirror task here means
            // the last committed transcript is in `committedText` before it is read.
            await events?.value
        }
        guard !Task.isCancelled else { return .cancelled }

        let (text, failure) = await MainActor.run {
            // A partial still pending at the stop is the next segment, and may finish a
            // word the last commit cut — joined like any other segment.
            (joinedSegments(committedText, partialText).trimmingCharacters(in: .whitespacesAndNewlines), self.failure)
        }

        if failure == nil, !text.isEmpty {
            dlog("Engine", "StreamingRecognitionSession.finish: stream done, \(text.count) chars")
            return RecognitionOutcome(text: text, error: nil, audioFileURL: nil, cancelled: false)
        }

        dlog("Engine", "StreamingRecognitionSession.finish: stream \(failure ?? "returned nothing") — falling back to batch upload")
        // The partial text on screen described a stream that is being discarded.
        await MainActor.run { onEvent?(.live(committed: "", partial: "")) }
        let outcome = await fallback.finish()
        await MainActor.run {
            DictationTraceRecorder.record(.fallback, text: outcome.text, error: outcome.error)
        }
        return outcome
    }

    func cancel() {
        sendEnabled = false
        eventsTask?.cancel()
        eventsTask = nil
        provider.cancel()
        fallback.cancel()
    }
}
