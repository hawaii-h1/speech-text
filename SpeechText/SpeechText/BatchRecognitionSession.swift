// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Batch upload

/// Writes the segment the engine's writer collected and uploads it. No live text.
final class BatchRecognitionSession: RecognitionSession {
    var onEvent: ((RecognitionEvent) -> Void)?

    private let provider: BatchSTTProvider
    private let writer: AudioBufferWriter
    /// nil leaves the language to the model — see `RecordingConfiguration.cloudLanguage`.
    private let language: String?

    init(provider: BatchSTTProvider, writer: AudioBufferWriter, language: String?) {
        self.provider = provider
        self.writer = writer
        self.language = language
    }

    /// Nothing to open.
    func start() throws {}

    /// The engine's writer already has the audio.
    func feed(native: AVAudioPCMBuffer, pcm16: Data?) {}

    /// The segment's text needs the upload.
    func pause() -> String? { nil }

    /// On failure the audio file is handed back rather than deleted, so the engine can
    /// archive it for a retry — a failed upload no longer means the speech is gone.
    func finish() async -> RecognitionOutcome {
        // Before the file is written: a press-and-release of the shortcut is not a
        // recording to archive, and a provider handed a fraction of a second answers
        // with an error (or, for Whisper, with a hallucinated sentence).
        let duration = writer.bufferedDuration
        if duration > 0, duration < STTTuning.minimumSegmentSeconds {
            dlog("Engine", "BatchRecognitionSession.finish: \(String(format: "%.2f", duration))s is too short to be speech — dropped")
            return .discarded
        }

        let fileURL: URL
        do {
            fileURL = try writer.writeAudioFile()
        } catch AudioBufferWriter.AudioBufferWriterError.noAudio {
            // A segment with no audio in it (a pause the instant after a resume) is an
            // empty result, not a failure: History would otherwise show it as an error
            // reading "No audio was recorded".
            dlog("Engine", "BatchRecognitionSession.finish: no audio in this segment")
            return RecognitionOutcome(text: "", error: nil, audioFileURL: nil, cancelled: Task.isCancelled)
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: could not write audio file: \(error.localizedDescription)")
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: nil, cancelled: Task.isCancelled)
        }

        // After the file is written, so the segment is still archived for a History retry
        // should the guard ever be wrong about a very quiet voice.
        guard writer.hasAudibleSignal else {
            dlog("Engine", "BatchRecognitionSession.finish: the segment is silent — not uploaded")
            return RecognitionOutcome(text: "", error: nil, audioFileURL: fileURL, cancelled: Task.isCancelled)
        }

        do {
            dlog("Engine", "BatchRecognitionSession.finish: calling provider, language=\(language ?? "auto")…")
            let text = try await provider.transcribe(audioFileURL: fileURL, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "BatchRecognitionSession.finish: done, \(text.count) chars")
            if HallucinationFilter.isHallucination(text, segmentSeconds: duration) {
                dlog("Engine", "BatchRecognitionSession.finish: the whole result is a known hallucination of a \(String(format: "%.1f", duration))s segment — dropped, audio kept")
                return RecognitionOutcome(text: "", error: nil, audioFileURL: fileURL, cancelled: false)
            }
            return RecognitionOutcome(text: text, error: nil, audioFileURL: fileURL, cancelled: false)
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: error: \(error.localizedDescription)")
            if Task.isCancelled {
                AudioBufferWriter.cleanup(fileURL: fileURL)
                return .cancelled
            }
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: fileURL, cancelled: false,
                                      offline: NetworkFailure.isOffline(error))
        }
    }

    /// The upload runs inside the engine's transcription task; cancelling that cancels
    /// the URLSession request.
    func cancel() {}
}
