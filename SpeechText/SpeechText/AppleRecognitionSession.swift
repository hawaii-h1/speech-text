// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Speech

// MARK: - Apple on-device

/// SFSpeechRecognitionTask stops accepting audio after roughly a minute. Left alone,
/// every word spoken past that point is silently dropped. The session rotates to a fresh
/// recognition task before the limit and stitches the chunks together.
///
/// State is main-thread only, except `request`, which `feed` reads from the audio thread
/// while a rotation swaps it on main — the same unsynchronised handoff the engine did.
final class AppleRecognitionSession: RecognitionSession {
    var onEvent: ((RecognitionEvent) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let locale: String
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Transcript committed from earlier chunks (see `rotate`).
    private var committedText = ""
    /// The current chunk's partial.
    private var partialText = ""
    /// Set on `isFinal`, or promoted from the live text when the recogniser errors.
    private var finalText = ""
    /// Recognition errors other than 216 (cancelled), as `RecognitionFailure` words them.
    private var lastError: String?
    /// The current chunk's task reported an error, so no further callback is coming.
    private var chunkFailed = false
    /// Incremented on every rotation so callbacks from retired chunks can be discarded.
    private var chunkToken = 0
    private var chunkTimer: Timer?
    /// Comfortably under SFSpeechRecognitionTask's ~60s ceiling.
    private let chunkDuration: TimeInterval = 50
    /// False once the mic stopped feeding this segment (pause / finish), so a rotation
    /// timer that fires late does not open a chunk nobody feeds.
    private var isFeeding = false
    private var isCancelled = false
    /// The `finish()` wait, resumed by `isFinal`, the 0.5 s deadline, or `cancel()`.
    /// Bool = cancelled.
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var finishDeadline: DispatchWorkItem?

    /// The user's vocabulary, fitted to Apple's limit — set on every chunk's request,
    /// since each rotation builds a new one.
    private let contextualStrings: [String]

    init(recognizer: SFSpeechRecognizer?, locale: String, contextualStrings: [String] = []) {
        self.recognizer = recognizer
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    func start() throws {
        // Denied or restricted: every task would fail, so the start does — with the
        // remedy. Not determined proceeds: the system asks on the first task.
        if Self.speechPermissionDenied {
            throw RecognitionSessionError.speechPermissionDenied
        }
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionSessionError.recognizerUnavailable(locale)
        }
        isFeeding = true
        startChunk(recognizer)
    }

    private static var speechPermissionDenied: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func startChunk(_ recognizer: SFSpeechRecognizer) {
        chunkFailed = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        self.request = request

        chunkToken += 1
        let token = chunkToken

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let partial = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async {
                    // Ignore late callbacks from a chunk we've already rotated away from.
                    guard self.chunkToken == token else { return }
                    self.partialText = partial
                    self.onEvent?(.live(committed: self.committedText, partial: self.partialText))
                    if isFinal {
                        dlog("Engine", "recognitionTask: isFinal=true, text=\(partial.prefix(80))")
                        self.finalText = joinedTranscript(self.committedText, self.partialText)
                        // No-op unless a finish is waiting, so isFinal during a chunk
                        // rotation or a pause changes nothing.
                        self.resolveFinish(cancelled: false)
                    }
                }
            }
            if let error {
                let nsErr = error as NSError
                dlog("Engine", "recognitionTask error: code=\(nsErr.code), domain=\(nsErr.domain), desc=\(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.chunkToken == token else { return }
                    // The task is over: a `finish()` that starts after this has nothing
                    // to wait for.
                    self.chunkFailed = true
                    if self.finalText.isEmpty {
                        self.finalText = joinedTranscript(self.committedText, self.partialText)
                    }
                    // Text from the whole segment, earlier chunks included: a fresh chunk
                    // that fails right after a rotation is not a recording without text.
                    let hasText = !joinedTranscript(self.committedText, self.partialText)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let permissionDenied = Self.speechPermissionDenied
                    if let failure = RecognitionFailure.apple(
                        domain: nsErr.domain, code: nsErr.code,
                        description: error.localizedDescription, hasText: hasText,
                        permissionDenied: permissionDenied, locale: self.locale) {
                        if !hasText {
                            dlog("Engine", "recognitionTask failed before any text: onDevice=\(self.recognizer?.supportsOnDeviceRecognition == true), permissionDenied=\(permissionDenied)")
                        }
                        self.lastError = failure.message
                        self.onEvent?(.failure(failure))
                    }
                    // Nothing more is coming after an error: a `finish()` waiting on this
                    // task gets its answer now rather than at the 0.5 s deadline.
                    self.resolveFinish(cancelled: false)
                }
            }
        }

        scheduleChunkRotation()
    }

    private func scheduleChunkRotation() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: false) { [weak self] _ in
            self?.rotate()
        }
    }

    private func rotate() {
        guard isFeeding, let recognizer else { return }
        let live = joinedTranscript(committedText, partialText)
        dlog("Engine", "AppleRecognitionSession.rotate: committing \(live.count) chars, starting fresh chunk")

        // Commit the latest partial. Partials arrive continuously, so this captures
        // essentially everything said in this chunk; at most a word at the boundary
        // is at risk, which beats losing every word after the one-minute mark.
        committedText = live.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = ""
        // An isFinal from the retired chunk described only that chunk. Left in place it
        // would make the stop return chunk 1 alone, dropping everything said after.
        finalText = ""

        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        // The tap appends to `request` by reference, so the running engine feeds the
        // new request automatically — no need to touch the tap.
        startChunk(recognizer)
    }

    private func stopChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }

    func feed(native: AVAudioPCMBuffer, pcm16: Data?) {
        // Apple's recognizer gets the native buffer — it does its own resampling.
        request?.append(native)
    }

    /// The task and request stay alive: a later stop-from-paused still ends the audio
    /// and waits for the final result, so Apple writes one history entry per stop.
    /// Idempotent — a stop calls it again (before `finish()`) so the rotation timer is
    /// killed on the main thread synchronously, not after `finish()`'s async hop.
    func pause() -> String? {
        isFeeding = false
        stopChunkTimer()
        return joinedTranscript(committedText, partialText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish() async -> RecognitionOutcome {
        let cancelled: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard !self.isCancelled else {
                    continuation.resume(returning: true)
                    return
                }
                self.isFeeding = false
                self.stopChunkTimer()
                self.request?.endAudio()
                guard !self.chunkFailed else {
                    // The task already ended with an error: no final result is coming,
                    // and waiting out the deadline would only hold the notice back.
                    dlog("Engine", "apple: task already failed, not waiting for a final result")
                    continuation.resume(returning: false)
                    return
                }
                dlog("Engine", "apple: waiting ≤0.5s for final result, live=\(joinedTranscript(self.committedText, self.partialText).count) chars")
                self.finishContinuation = continuation
                // 0.5s is the upper bound; the recognition callback resolves this early
                // when a result with `isFinal` arrives, so the user isn't kept waiting on a timer.
                let deadline = DispatchWorkItem { [weak self] in
                    self?.resolveFinish(cancelled: false)
                }
                self.finishDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: deadline)
            }
        }
        guard !cancelled else { return .cancelled }

        return await MainActor.run {
            var text = finalText
            if text.isEmpty {
                let live = joinedTranscript(committedText, partialText)
                dlog("Engine", "apple: finalText empty, using live text (\(live.count) chars)")
                text = live
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "apple: done, finalText=\(text.count) chars")
            return RecognitionOutcome(text: text, error: lastError, audioFileURL: nil, cancelled: false)
        }
    }

    private func resolveFinish(cancelled: Bool) {
        guard let continuation = finishContinuation else { return }
        if !cancelled, finishDeadline?.isCancelled == false, finalText.isEmpty == false {
            dlog("Engine", "apple: final result arrived, finishing early")
        }
        finishContinuation = nil
        finishDeadline?.cancel()
        finishDeadline = nil
        continuation.resume(returning: cancelled)
    }

    func cancel() {
        isCancelled = true
        isFeeding = false
        stopChunkTimer()
        task?.cancel()
        task = nil
        request = nil
        // Drops late callbacks from the cancelled task.
        chunkToken += 1
        resolveFinish(cancelled: true)
    }
}
