// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os.log

private let histLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                             category: "History")

// MARK: - Record

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case success
        case empty
        case failed
    }

    /// The LLM pass, when the dictation went through one. `text` always stays the raw
    /// transcription, so both versions survive and can be compared after the fact.
    struct Refinement: Codable, Equatable {
        /// What was actually sent to the model. Usually equals the record's `text`, but
        /// the Record Window refines its whole text area, which can span several
        /// segments and manual edits — so it is stored rather than assumed.
        var inputText: String
        var outputText: String
        /// Preset the model routed to, when it reported one on the `<<mode:…>>` line.
        var presetName: String?
        var provider: String
        var model: String
        /// Set when the LLM step failed; the raw transcription was used instead.
        var errorMessage: String?
        /// The app, window and field the model was told the text was for. Nil for the
        /// Record Window, for entries older than the setting, and when it was off.
        var context: FocusContext? = nil
        /// The Edit shortcut's rewrite of text selected in another app: `inputText` is the
        /// selection, and the record's `text` the spoken instruction ("" with none).
        var editsSelection: Bool? = nil

        var isSelectionEdit: Bool { editsSelection == true }
        var succeeded: Bool { errorMessage == nil && !outputText.isEmpty }
    }

    let id: UUID
    let date: Date
    var text: String
    var status: Status
    var errorMessage: String?
    let provider: String
    let locale: String?
    let duration: TimeInterval
    /// Filename (not a full path — the container may move) of the archived audio kept
    /// so a failed transcription can be retried instead of being lost.
    var audioFileName: String?
    /// Optional, so history written before AI mode existed still decodes.
    var refinement: Refinement?
    /// The app an inline dictation started in, and the one it was pasted into — the app
    /// in front at the stop (#77). Nil for the Record Window, for an edit, and for entries
    /// written before the stop chose where the text went.
    var originApp: String?
    var destinationApp: String?

    var isRetryable: Bool { audioFileName != nil && status != .success }

    /// What the user actually received — the refined text when the LLM pass worked,
    /// otherwise the raw transcription.
    var deliveredText: String {
        guard let refinement, refinement.succeeded else { return text }
        return refinement.outputText
    }
}

// MARK: - Store

@Observable
final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    /// Newest first.
    private(set) var records: [TranscriptionRecord] = []

    /// Cap on retained entries. Archived audio for pruned entries is deleted with them.
    private let maxRecords = 300
    /// Archived audio is only useful for a retry; expire it so the disk doesn't grow forever.
    private let audioRetention: TimeInterval = 7 * 24 * 60 * 60

    private let ioQueue = DispatchQueue(label: "app.speech-text.SpeechText.history.io")
    /// The write scheduled by the last mutation, or nil when nothing is pending.
    /// Main-thread-only, like `records`.
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// How long a burst of mutations is allowed to coalesce into one write.
    private let saveCoalescingDelay: TimeInterval = 0.25

    private init() {
        adoptPreRenameStore()
        load()
        pruneExpiredAudio()
    }

    // MARK: Paths

    private var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SpeechText", isDirectory: true)
    }

    /// Folder names this app kept its history under before, newest first: it shipped as
    /// VoicePeter, then under the misspelled SpeachText. Move the newest one that still
    /// exists across, once, so a rename doesn't silently look like data loss.
    private static let preRenameStoreNames = ["SpeachText", "VoicePeter"]

    private func adoptPreRenameStore() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: baseDirectory.path) else { return }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in Self.preRenameStoreNames {
            let legacy = support.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            do {
                try fm.moveItem(at: legacy, to: baseDirectory)
                histLog.info("migrated history store from \(name, privacy: .public) to SpeechText")
            } catch {
                histLog.error("could not migrate history store: \(error.localizedDescription)")
            }
            return
        }
    }

    private var historyFileURL: URL {
        baseDirectory.appendingPathComponent("history.json")
    }

    private var recordingsDirectory: URL {
        baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Full path of the archived audio for a record, if it still exists on disk.
    func audioURL(for record: TranscriptionRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = recordingsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: Recording outcomes

    /// Returns the new record's id so a later LLM pass can be attached to this entry.
    @discardableResult
    func recordSuccess(text: String, provider: String, locale: String?,
                       duration: TimeInterval) -> UUID {
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: text, status: .success,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: nil))
        return id
    }

    /// Where an inline dictation started and where it was pasted.
    func recordApps(id: UUID, origin: String?, destination: String?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].originApp = origin
        records[index].destinationApp = destination
        save()
    }

    // MARK: LLM pass

    /// Attaches the result of the AI step to an existing transcription entry.
    func recordRefinement(id: UUID, input: String, output: String, presetName: String?,
                          provider: String, model: String, context: FocusContext? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: nil, context: context
        ))
    }

    /// Records that the AI step was attempted and failed. Worth keeping: the pasted text
    /// silently differs from what the user asked for, and the entry explains why.
    func recordRefinementFailure(id: UUID, input: String, error: String,
                                 provider: String, model: String, context: FocusContext? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: "", presetName: nil,
            provider: provider, model: model, errorMessage: error, context: context
        ))
    }

    /// The Edit shortcut's rewrite. It belongs to the spoken instruction's record when
    /// there was one (`recordID`); an edit with no instruction gets a record of its own,
    /// whose text — the instruction — is empty.
    func recordSelectionEdit(recordID: UUID?, selection: String, output: String, error: String?,
                             presetName: String?, provider: String, model: String,
                             context: FocusContext?) {
        let refinement = TranscriptionRecord.Refinement(
            inputText: selection, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: error, context: context,
            editsSelection: true)
        if let recordID, records.contains(where: { $0.id == recordID }) {
            updateRefinement(id: recordID, refinement)
            return
        }
        var record = TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .success,
                                         errorMessage: nil, provider: "edit", locale: nil,
                                         duration: 0, audioFileName: nil)
        record.refinement = refinement
        add(record)
    }

    private func updateRefinement(id: UUID, _ refinement: TranscriptionRecord.Refinement) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            histLog.info("refinement for unknown record \(id.uuidString, privacy: .public) — dropped")
            return
        }
        records[index].refinement = refinement
        save()
    }

    /// Records a failure and *keeps* the audio so the user can retry it. Passing the temp
    /// audio file here transfers ownership — do not call `AudioBufferWriter.cleanup` on it after.
    /// Returns the new record's id, so a failure the user can retry can name its row.
    @discardableResult
    func recordFailure(error: String, provider: String, locale: String?,
                       duration: TimeInterval, audioURL: URL?) -> UUID {
        let archived = archive(audioURL: audioURL)
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: "", status: .failed,
                                errorMessage: error, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived))
        return id
    }

    func record(id: UUID) -> TranscriptionRecord? {
        records.first { $0.id == id }
    }

    /// Transcription succeeded technically but produced no words. Audio is kept too —
    /// an empty result is often a provider hiccup worth retrying.
    func recordEmpty(provider: String, locale: String?, duration: TimeInterval, audioURL: URL?) {
        let archived = archive(audioURL: audioURL)
        add(TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .empty,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived))
    }

    /// Replace a failed record's outcome after a successful retry.
    func markRetrySucceeded(id: UUID, text: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        // The audio has served its purpose — reclaim the disk.
        if let url = audioURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        record.text = text
        record.status = .success
        record.errorMessage = nil
        record.audioFileName = nil
        // The old refinement described text that no longer exists.
        record.refinement = nil
        records[index] = record
        save()
    }

    func markRetryFailed(id: UUID, error: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].errorMessage = error
        save()
    }

    // MARK: Mutation

    private func add(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        if records.count > maxRecords {
            let dropped = records[maxRecords...]
            dropped.forEach(deleteAudio)
            records.removeLast(records.count - maxRecords)
        }
        histLog.info("recorded \(record.status.rawValue, privacy: .public) entry, \(record.text.count) chars")
        save()
    }

    func delete(_ record: TranscriptionRecord) {
        deleteAudio(record)
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.forEach(deleteAudio)
        records.removeAll()
        save()
    }

    private func deleteAudio(_ record: TranscriptionRecord) {
        guard let url = audioURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Audio archive

    /// Move a temp audio file into the archive. Returns the stored filename, or nil if
    /// there was no audio or the move failed (in which case the record is still kept).
    /// The file keeps its extension (`.flac` normally, `.wav` on the writer's fallback
    /// and for entries archived before FLAC uploads existed): the retry path reads the
    /// MIME type off it, so the archive must not rename everything to one container.
    private func archive(audioURL: URL?) -> String? {
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        ensureDirectories()

        let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = recordingsDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at: audioURL, to: destination)
            dlog("History", "archived audio for retry: \(filename)")
            return filename
        } catch {
            histLog.error("archive failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
    }

    private func pruneExpiredAudio() {
        let cutoff = Date().addingTimeInterval(-audioRetention)
        var changed = false
        for index in records.indices where records[index].audioFileName != nil {
            guard records[index].date < cutoff else { continue }
            deleteAudio(records[index])
            records[index].audioFileName = nil
            changed = true
        }
        if changed { save() }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: historyFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            records = try decoder.decode([TranscriptionRecord].self, from: data)
        } catch {
            histLog.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Schedules one write for a burst of mutations.
    ///
    /// A single dictation mutates the store several times (the record, the apps it went
    /// between, its refinement), and each write re-encodes up to 300 entries. The pending write is
    /// cancelled and re-scheduled instead of stacking, so a burst costs one encode. The
    /// snapshot is taken when the write *fires*, so it is always the latest state.
    ///
    /// `records` and `pendingSave` are both main-thread-only — a `save()` from anywhere
    /// else hops to main rather than taking a lock.
    private func save() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.save() }
            return
        }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.writeNow(records: self.records)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveCoalescingDelay, execute: work)
    }

    /// Writes any pending change immediately, on the calling thread. Called at
    /// termination, where an asynchronous write would not land before the process exits.
    func flush() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.flush() }
            return
        }
        if let work = pendingSave {
            work.cancel()
            pendingSave = nil
            writeNow(records: records, synchronously: true)
        } else {
            // Nothing pending, but a write scheduled a moment ago may still be in flight.
            ioQueue.sync {}
        }
    }

    private func writeNow(records snapshot: [TranscriptionRecord], synchronously: Bool = false) {
        let url = historyFileURL
        let write = { [weak self] in
            guard let self else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            do {
                self.ensureDirectories()
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                histLog.error("save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if synchronously { ioQueue.sync(execute: write) } else { ioQueue.async(execute: write) }
    }
}
