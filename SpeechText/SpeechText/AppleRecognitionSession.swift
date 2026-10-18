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
    /// The current chunk's results, kept across the recogniser's resets after a pause
    /// and its empty finals (`AppleUtterances`, #175).
    private var utterances = AppleUtterances()
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

    /// The Dictionary's words, fitted to Apple's limit
    /// (`RecordingConfiguration.liveVocabulary`) — set on every chunk's request,
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
                    let before = self.utterances
                    self.utterances.receive(partial)
                    if self.utterances.settled != before.settled {
                        dlog("Engine", "apple: a new utterance began — keeping the \(transcriptWords(before.current).count) words before it")
                    }
                    // What the recogniser has moved past is committed: it will not revise it.
                    self.onEvent?(.live(committed: joinedTranscript(self.committedText, self.utterances.settled),
                                        partial: self.utterances.current))
                    if isFinal {
                        dlog("Engine", "recognitionTask: isFinal=true, \(partial.count) chars"
                             + (partial.isEmpty ? " — keeping the \(self.utterances.text.count) chars heard before it" : ""))
                        self.finalText = joinedTranscript(self.committedText, self.utterances.text)
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
                        self.finalText = joinedTranscript(self.committedText, self.utterances.text)
                    }
                    // Text from the whole segment, earlier chunks included: a fresh chunk
                    // that fails right after a rotation is not a recording without text.
                    let hasText = !joinedTranscript(self.committedText, self.utterances.text)
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
        let live = joinedTranscript(committedText, utterances.text)
        dlog("Engine", "AppleRecognitionSession.rotate: committing \(live.count) chars, starting fresh chunk")

        // Commit the latest partial. Partials arrive continuously, so this captures
        // essentially everything said in this chunk; at most a word at the boundary
        // is at risk, which beats losing every word after the one-minute mark.
        committedText = live.trimmingCharacters(in: .whitespacesAndNewlines)
        utterances = AppleUtterances()
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

    /// The task and request stay alive, so a stop from a pause that had recognised
    /// nothing yet can still end the audio and wait for a final result. A pause with text
    /// has its History row written by the engine there and then, and the stop does not
    /// finish this session again — it would write the same segment twice.
    /// Idempotent — a stop calls it again (before `finish()`) so the rotation timer is
    /// killed on the main thread synchronously, not after `finish()`'s async hop.
    func pause() -> String? {
        isFeeding = false
        stopChunkTimer()
        return joinedTranscript(committedText, utterances.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish() async -> RecognitionOutcome {
        // Handed to the main queue unchecked: the closure below runs on main, and
        // everything it touches — `isCancelled`, `isFeeding`, the chunk timer, the
        // request's `endAudio`, `chunkFailed`, the transcript it logs,
        // `finishContinuation`, `finishDeadline` — is otherwise only changed on main too
        // (the recogniser's callbacks and the timer hop there), so this shares nothing
        // across threads. The class is not `Sendable` as a whole: `feed` reads `request`
        // from the audio thread.
        nonisolated(unsafe) let session = self
        let cancelled: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard !session.isCancelled else {
                    continuation.resume(returning: true)
                    return
                }
                session.isFeeding = false
                session.stopChunkTimer()
                session.request?.endAudio()
                guard !session.chunkFailed else {
                    // The task already ended with an error: no final result is coming,
                    // and waiting out the deadline would only hold the notice back.
                    dlog("Engine", "apple: task already failed, not waiting for a final result")
                    continuation.resume(returning: false)
                    return
                }
                dlog("Engine", "apple: waiting ≤0.5s for final result, live=\(joinedTranscript(session.committedText, session.utterances.text).count) chars")
                session.finishContinuation = continuation
                // 0.5s is the upper bound; the recognition callback resolves this early
                // when a result with `isFinal` arrives, so the user isn't kept waiting on a timer.
                let deadline = DispatchWorkItem { [weak session = session] in
                    session?.resolveFinish(cancelled: false)
                }
                session.finishDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: deadline)
            }
        }
        guard !cancelled else { return .cancelled }

        return await MainActor.run {
            var text = finalText
            if text.isEmpty {
                let live = joinedTranscript(committedText, utterances.text)
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

// MARK: - Languages on this Mac

/// Which of the user's languages Apple's recogniser takes on-device on this Mac — the answer
/// `LanguageCoverage.decidedBySystem` stands for (#30). Asked of macOS, never written down:
/// it follows the Dictation languages installed, so it differs from Mac to Mac. It does not
/// need the Speech Recognition permission: on 2026-10-17, with the permission not yet asked,
/// macOS answered true for en-US and uk-UA and false for es-ES ("No Assistant asset").
enum AppleOnDeviceLanguages {
    @MainActor private static var answers: [String: Bool] = [:]

    /// True or false once macOS has said; nil for a code with no Apple locale, which then
    /// stays silent. A locale macOS cannot recognise at all is false.
    @MainActor static func supports(_ code: String) -> Bool? {
        guard let locale = spokenLanguage(id: languageSubtag(code))?.localeIdentifier else { return nil }
        if let known = answers[locale] { return known }
        let answer = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
        answers[locale] = answer
        return answer
    }

    /// Forgets the answers, so a page that appears asks again — the user may have added a
    /// Dictation language in System Settings meanwhile.
    @MainActor static func refresh() { answers = [:] }
}
