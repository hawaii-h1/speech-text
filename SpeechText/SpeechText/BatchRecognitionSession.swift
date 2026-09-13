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
    private let locale: String

    init(provider: BatchSTTProvider, writer: AudioBufferWriter, locale: String) {
        self.provider = provider
        self.writer = writer
        self.locale = locale
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
        let fileURL: URL
        do {
            fileURL = try writer.writeAudioFile()
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: could not write audio file: \(error.localizedDescription)")
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: nil, cancelled: Task.isCancelled)
        }

        do {
            dlog("Engine", "BatchRecognitionSession.finish: calling provider, locale=\(locale)…")
            let text = try await provider.transcribe(audioFileURL: fileURL, language: locale).trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "BatchRecognitionSession.finish: done, \(text.count) chars")
            return RecognitionOutcome(text: text, error: nil, audioFileURL: fileURL, cancelled: false)
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: error: \(error.localizedDescription)")
            if Task.isCancelled {
                AudioBufferWriter.cleanup(fileURL: fileURL)
                return .cancelled
            }
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: fileURL, cancelled: false)
        }
    }

    /// The upload runs inside the engine's transcription task; cancelling that cancels
    /// the URLSession request.
    func cancel() {}
}
