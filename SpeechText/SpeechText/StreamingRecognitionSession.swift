import Foundation
import AVFoundation

// MARK: - Streaming with batch fallback

/// Pushes the writer's 16 kHz bytes over the realtime socket and mirrors its events into
/// committed / partial text. When the stream breaks or ends with nothing, `finish()`
/// hands the segment to the wrapped batch session, which uploads the same writer's file.
final class StreamingRecognitionSession: RecognitionSession {
    var onEvent: ((RecognitionEvent) -> Void)?

    private let provider: StreamingSTTProvider
    private let writer: AudioBufferWriter
    private let locale: String
    private let fallback: BatchRecognitionSession

    // Main-thread state.
    private var committedText = ""
    private var partialText = ""
    /// Set when the stream broke; `finish()` then falls back to the batch upload.
    private var failure: String?
    private var connected = false
    private var eventsTask: Task<Void, Never>?
    /// Read from the audio thread; cleared on main once a failure is known so no audio
    /// is pushed into a stream that will be discarded.
    private var sendEnabled = true

    init(provider: StreamingSTTProvider, writer: AudioBufferWriter, locale: String,
         fallback: BatchRecognitionSession) {
        self.provider = provider
        self.writer = writer
        self.locale = locale
        self.fallback = fallback
    }

    func start() throws {
        guard provider.sampleRate == AudioBufferWriter.uploadSampleRate else {
            dlog("Engine", "stream wants \(provider.sampleRate) Hz, tap converts to \(AudioBufferWriter.uploadSampleRate) — stream will be skipped")
            markFailed("Could not convert audio for streaming")
            return
        }
        connected = true
        provider.connect(language: locale)
        let provider = self.provider
        eventsTask = Task { [weak self] in
            for await event in provider.events {
                await MainActor.run { self?.handle(event) }
            }
        }
    }

    private func handle(_ event: StreamingSTTEvent) {
        switch event {
        case .partial(let text):
            partialText = text
        case .committed(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                committedText = joinedTranscript(committedText, trimmed)
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
            (joinedTranscript(committedText, partialText).trimmingCharacters(in: .whitespacesAndNewlines), self.failure)
        }

        if failure == nil, !text.isEmpty {
            dlog("Engine", "StreamingRecognitionSession.finish: stream done, \(text.count) chars")
            return RecognitionOutcome(text: text, error: nil, audioFileURL: nil, cancelled: false)
        }

        dlog("Engine", "StreamingRecognitionSession.finish: stream \(failure ?? "returned nothing") — falling back to batch upload")
        // The partial text on screen described a stream that is being discarded.
        await MainActor.run { onEvent?(.live(committed: "", partial: "")) }
        return await fallback.finish()
    }

    func cancel() {
        sendEnabled = false
        eventsTask?.cancel()
        eventsTask = nil
        provider.cancel()
        fallback.cancel()
    }
}
