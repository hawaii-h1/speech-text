// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Retrying an archived recording

/// Transcribes a History entry's archived audio again. One owner for every way a retry
/// starts — History's button, the "No connection" notice's Retry — so the same record is
/// never sent twice at once and History's spinner shows a retry whoever began it.
///
/// App target only: it reads `RecordingConfiguration.current()`, since a retry exists to
/// try the settings the user has *now*.
@MainActor
@Observable
final class HistoryRetry {
    static let shared = HistoryRetry()

    /// Records being retried right now.
    private(set) var inFlight: Set<UUID> = []

    enum Result: Equatable {
        /// The record now holds this text.
        case succeeded(String)
        /// Still no network; the record keeps its audio and its row says so.
        case offline
        /// Anything else, as History now shows it.
        case failed(String)
        /// A retry of this record was already running; this one did nothing.
        case alreadyRunning
    }

    private var history: TranscriptionHistory { .shared }

    /// Retries one record and writes the result into History. Returns what happened, so
    /// the caller can tell the user — History shows it in the row by itself.
    @discardableResult
    func retry(_ recordID: UUID) async -> Result {
        guard !inFlight.contains(recordID) else { return .alreadyRunning }
        guard let record = history.record(id: recordID),
              let audioURL = history.audioURL(for: record) else {
            let message = "Saved audio is no longer available"
            history.markRetryFailed(id: recordID, error: message)
            return .failed(message)
        }

        // Read fresh: a retry honours the *current* settings, not the ones the
        // recording was made with.
        let configuration = RecordingConfiguration.current()

        // Retries always go through a file transcription — Apple's recognizer has no
        // batch API, so an Apple selection retries through Groq — and that path must be
        // able to start: a key for the cloud tiers, an installed model for the local one.
        if let reason = configuration.batchUnavailableReason() {
            history.markRetryFailed(id: recordID, error: reason)
            return .failed(reason)
        }

        inFlight.insert(recordID)
        defer { inFlight.remove(recordID) }
        // The language comes from the current settings too, not from the record: a
        // retry exists precisely because the first attempt came back wrong, and an
        // entry recorded under a mis-guessed language would repeat that guess.
        let language = configuration.cloudLanguage
        dlog("History", "retry \(recordID.uuidString.prefix(8)): \(configuration.provider.rawValue), language=\(language ?? "auto")")

        do {
            let provider = makeBatchProvider(configuration: configuration)
            let text = try await provider.transcribe(audioFileURL: audioURL, language: language)
            let trimmed = configuration.cleaned(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !trimmed.isEmpty else {
                let message = "Retry returned no text"
                history.markRetryFailed(id: recordID, error: message)
                return .failed(message)
            }
            history.markRetrySucceeded(id: recordID, text: trimmed)
            return .succeeded(trimmed)
        } catch {
            dlog("History", "retry \(recordID.uuidString.prefix(8)) failed: \(error.localizedDescription)")
            history.markRetryFailed(id: recordID, error: error.localizedDescription)
            return NetworkFailure.isOffline(error) ? .offline : .failed(error.localizedDescription)
        }
    }
}
