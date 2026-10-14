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
        /// The tokens the provider billed for the pass, when it reported them — what Usage
        /// prices. Nil for a pass that never got a reply, and for entries written before
        /// it was kept, which Usage estimates from their words.
        var usage: ChatUsage? = nil

        var isSelectionEdit: Bool { editsSelection == true }
        var succeeded: Bool { errorMessage == nil && !outputText.isEmpty }
    }

    let id: UUID
    let date: Date
    var text: String
    var status: Status
    var errorMessage: String?
    /// The speech engine's `STTProviderType` raw value. A retry that succeeds rewrites
    /// it with the engine that transcribed it then. `noSpeechProvider` for an edit sent
    /// with no spoken instruction, which no engine heard.
    var provider: String
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
    /// The speech model's ID (`STTModelDescriptor.id`) — the one selected, for a stream
    /// that fell back to its upload too. Nil for entries written before it was kept, which
    /// Usage then names by their engine alone.
    var sttModel: String?
    /// Every request this record cost (`UsageEvent`), oldest first. Nil for records
    /// written before the ledger was kept, which Usage prices the old way; empty for one
    /// that sent nothing anywhere — Apple, a model on this Mac, or a silent segment.
    var usageEvents: [UsageEvent]?

    var isRetryable: Bool { audioFileName != nil && status != .success }

    /// The `provider` of an edit sent with no instruction (a double press): nothing was
    /// recorded, so no engine heard anything and Usage counts no speech for it.
    static let noSpeechProvider = "edit"

    /// Whether a speech engine heard anything for this record.
    var hasSpeech: Bool { provider != Self.noSpeechProvider }

    /// What the user actually received — the refined text when the LLM pass worked,
    /// otherwise the raw transcription.
    var deliveredText: String {
        guard let refinement, refinement.succeeded else { return text }
        return refinement.outputText
    }
}

// MARK: - Usage ledger

/// One request to a vendor, as metering counts it: what was sent and what the vendor
/// said it billed. A record keeps one per request in `usageEvents` — a stream and the
/// upload it fell back to are two, a retry is another, a rewrite another — so Usage
/// counts the work that was paid for, not the one result that survived. Prices are not
/// stored: the units are, and Usage prices them.
struct UsageEvent: Codable, Equatable {
    enum Kind: String, Codable {
        /// A segment's file upload — including a stream's fallback.
        case upload
        /// A realtime socket, reconnects included.
        case stream
        /// History's retry of an archived recording.
        case retry
        /// AI Rewrite, or the Record Window's ✨.
        case rewrite
        /// The Edit shortcut's rewrite of a selection.
        case edit

        /// A speech request — priced by its audio, whatever else its reply reported
        /// (OpenAI's token-billed transcriptions carry tokens too).
        var isSpeech: Bool { self == .upload || self == .stream || self == .retry }
    }

    let date: Date
    let kind: Kind
    /// The vendor actually called — Groq for an Apple session's upload.
    let vendor: Provider
    let model: String
    /// The vendor answered, whatever the answer held — for a stream, the socket did not
    /// break; one that answered with nothing still counts, as its fallback upload is
    /// what shows it was paid for twice.
    let succeeded: Bool
    /// Audio sent, in seconds; nil for a chat request.
    var audioSeconds: Double? = nil
    /// The vendor's own figure, or its documented minimum (`UsageMeter`); nil when
    /// neither is known — then only `audioSeconds` is.
    var billedSeconds: Double? = nil
    /// A chat request's tokens, or a token-billed transcription's.
    var tokens: ChatUsage? = nil
    /// Terms sent with a speech request (ElevenLabs bills a surcharge for them).
    var keyterms: Int? = nil
    /// Seconds from sending the request to its answer.
    var latency: Double? = nil
}

// MARK: - Store

@Observable
final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    /// Newest first.
    private(set) var records: [TranscriptionRecord] = []

    /// How long History keeps dictations (`SettingsKeys.historyRetention`): forever until
    /// the user chooses otherwise. Entries it lets go take their archived audio with them.
    var retention: HistoryRetention {
        HistoryRetention.stored(UserDefaults.standard.string(forKey: SettingsKeys.historyRetention))
    }
    /// How long a failed dictation's audio is kept for a retry (`SettingsKeys.failedAudioRetention`):
    /// a week until the user chooses otherwise.
    var audioRetention: HistoryRetention {
        HistoryRetention.stored(UserDefaults.standard.string(forKey: SettingsKeys.failedAudioRetention),
                                default: .defaultAudio)
    }
    /// When this run of the app began — what *Don't keep* keeps from.
    let sessionStart = Date()

    private let ioQueue = DispatchQueue(label: "app.speech-text.SpeechText.history.io")
    /// The write scheduled by the last mutation, or nil when nothing is pending.
    /// Main-thread-only, like `records`.
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// How long a burst of mutations is allowed to coalesce into one write.
    private let saveCoalescingDelay: TimeInterval = 0.25

    private init() {
        adoptPreRenameStore()
        load()
        // A span of time lets entries go as the days pass, not only when one is added.
        applyRetention()
    }

    // MARK: Paths

    private var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(E2EMode.supportFolderName, isDirectory: true)
    }

    /// Folder names this app kept its history under before, newest first: it shipped as
    /// VoicePeter, then under the misspelled SpeachText. Move the newest one that still
    /// exists across, once, so a rename doesn't silently look like data loss.
    private static let preRenameStoreNames = ["SpeachText", "VoicePeter"]

    private func adoptPreRenameStore() {
        let fm = FileManager.default
        guard !E2EMode.isActive, !fm.fileExists(atPath: baseDirectory.path) else { return }
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

    /// What History takes on disk: its file and the audio kept for retries.
    func diskBytes() -> Int64 {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 {
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).flatMap { $0 }
                .map(Int64.init) ?? 0
        }
        let audio = (try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]))
            ?? []
        return size(historyFileURL) + audio.reduce(0) { $0 + size($1) }
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
    func recordSuccess(text: String, provider: String, model: String? = nil, locale: String?,
                       duration: TimeInterval, usage: [UsageEvent] = []) -> UUID {
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: text, status: .success,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: nil, sttModel: model, usageEvents: usage))
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
                          provider: String, model: String, context: FocusContext? = nil,
                          usage: ChatUsage? = nil, latency: Double? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: nil, context: context, usage: usage
        ), latency: latency)
    }

    /// Records that the AI step was attempted and failed. Worth keeping: the pasted text
    /// silently differs from what the user asked for, and the entry explains why.
    /// `usage`: a reply that came back and was refused by us (the Record Window's collapse
    /// guard) was still billed.
    func recordRefinementFailure(id: UUID, input: String, error: String,
                                 provider: String, model: String, context: FocusContext? = nil,
                                 usage: ChatUsage? = nil, latency: Double? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: "", presetName: nil,
            provider: provider, model: model, errorMessage: error, context: context, usage: usage
        ), latency: latency)
    }

    /// The Edit shortcut's rewrite. It belongs to the spoken instruction's record when
    /// there was one (`recordID`); an edit with no instruction gets a record of its own,
    /// whose text — the instruction — is empty.
    func recordSelectionEdit(recordID: UUID?, selection: String, output: String, error: String?,
                             presetName: String?, provider: String, model: String,
                             context: FocusContext?, usage: ChatUsage? = nil, latency: Double? = nil) {
        let refinement = TranscriptionRecord.Refinement(
            inputText: selection, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: error, context: context,
            editsSelection: true, usage: usage)
        if let recordID, records.contains(where: { $0.id == recordID }) {
            updateRefinement(id: recordID, refinement, latency: latency)
            return
        }
        var record = TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .success,
                                         errorMessage: nil, provider: TranscriptionRecord.noSpeechProvider, locale: nil,
                                         duration: 0, audioFileName: nil, usageEvents: [])
        record.refinement = refinement
        record.usageEvents?.append(contentsOf: Self.chatEvent(for: refinement, latency: latency).map { [$0] } ?? [])
        add(record)
    }

    /// The pass written onto the record, and its request onto the record's ledger — which
    /// a later retry's cleared refinement cannot take back: it was billed all the same.
    /// A record from before the ledger (`usageEvents == nil`) gets no entries at all:
    /// one entry would make Usage price it from the ledger alone and lose its speech.
    private func updateRefinement(id: UUID, _ refinement: TranscriptionRecord.Refinement, latency: Double?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            histLog.info("refinement for unknown record \(id.uuidString, privacy: .public) — dropped")
            return
        }
        records[index].refinement = refinement
        if let event = Self.chatEvent(for: refinement, latency: latency) {
            records[index].usageEvents?.append(event)
        }
        save()
    }

    /// The ledger entry for an LLM pass. A pass that got a reply counts as answered,
    /// even one refused afterwards (the Record Window's collapse guard); one with no
    /// reply — a missing key, an HTTP error — sent no tokens anyone billed. Nil when the
    /// provider is one History cannot name.
    static func chatEvent(for refinement: TranscriptionRecord.Refinement, latency: Double?,
                          date: Date = Date()) -> UsageEvent? {
        guard let vendor = LLMProviderType(rawValue: refinement.provider)?.vendor else { return nil }
        return UsageEvent(date: date, kind: refinement.isSelectionEdit ? .edit : .rewrite, vendor: vendor,
                          model: refinement.model, succeeded: refinement.usage != nil || refinement.succeeded,
                          tokens: refinement.usage, latency: latency)
    }

    /// Records a failure and *keeps* the audio so the user can retry it. Passing the temp
    /// audio file here transfers ownership — do not call `AudioBufferWriter.cleanup` on it after.
    /// Returns the new record's id, so a failure the user can retry can name its row.
    @discardableResult
    func recordFailure(error: String, provider: String, model: String? = nil, locale: String?,
                       duration: TimeInterval, audioURL: URL?, usage: [UsageEvent] = []) -> UUID {
        let archived = archive(audioURL: audioURL)
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: "", status: .failed,
                                errorMessage: error, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived, sttModel: model, usageEvents: usage))
        return id
    }

    func record(id: UUID) -> TranscriptionRecord? {
        records.first { $0.id == id }
    }

    /// Transcription succeeded technically but produced no words. Audio is kept too —
    /// an empty result is often a provider hiccup worth retrying.
    func recordEmpty(provider: String, model: String? = nil, locale: String?, duration: TimeInterval, audioURL: URL?,
                     usage: [UsageEvent] = []) {
        let archived = archive(audioURL: audioURL)
        add(TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .empty,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived, sttModel: model, usageEvents: usage))
    }

    /// Replace a failed record's outcome after a successful retry.
    /// `provider` and `model`: the engine the retry went to — the current settings', not
    /// the recording's — so Usage counts and prices the work where it was done.
    /// `event`: the retry's own request, added to the ledger — the attempts before it
    /// were billed too, and stay. Not added to a record from before the ledger, which
    /// Usage keeps pricing the old way.
    func markRetrySucceeded(id: UUID, text: String, provider: String? = nil, model: String? = nil,
                            event: UsageEvent? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        if let event { record.usageEvents?.append(event) }
        // The audio has served its purpose — reclaim the disk.
        if let url = audioURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        record.text = text
        record.status = .success
        record.errorMessage = nil
        record.audioFileName = nil
        if let provider {
            record.provider = provider
            record.sttModel = model
        }
        // The old refinement described text that no longer exists.
        record.refinement = nil
        records[index] = record
        save()
    }

    func markRetryFailed(id: UUID, error: String, event: UsageEvent? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].errorMessage = error
        if let event { records[index].usageEvents?.append(event) }
        save()
    }

    // MARK: Mutation

    private func add(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        trim(to: retention)
        histLog.info("recorded \(record.status.rawValue, privacy: .public) entry, \(record.text.count) chars")
        save()
    }

    /// How many entries `retention` would let go right now — what Settings asks about
    /// before a shorter choice deletes them.
    func droppedCount(under retention: HistoryRetention) -> Int {
        records.count - retention.keptCount(of: records, sessionStart: sessionStart)
    }

    /// How many failed dictations' audio `audioRetention` would delete right now.
    func droppedAudioCount(under audioRetention: HistoryRetention) -> Int {
        expiredAudio(under: audioRetention, sessionStart: sessionStart).count
    }

    /// Lets go of what the stored choices no longer keep — at launch, and once the user has
    /// agreed to a shorter one in Settings.
    func applyRetention() {
        let trimmed = trim(to: retention)
        if pruneExpiredAudio(sessionStart: sessionStart) || trimmed { save() }
    }

    /// At quit: what *Don't keep* kept for this session goes now.
    func applyRetentionAtQuit() {
        let quitting = Date.distantFuture
        let trimmed = trim(to: retention, sessionStart: quitting)
        if pruneExpiredAudio(sessionStart: quitting) || trimmed { save() }
    }

    @discardableResult
    private func trim(to retention: HistoryRetention, sessionStart: Date? = nil) -> Bool {
        let kept = retention.keptCount(of: records, sessionStart: sessionStart ?? self.sessionStart)
        guard kept < records.count else { return false }
        records[kept...].forEach(deleteAudio)
        records.removeLast(records.count - kept)
        return true
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

    /// The records whose archived audio `audioRetention` no longer keeps.
    private func expiredAudio(under audioRetention: HistoryRetention, sessionStart: Date) -> [Int] {
        guard let cutoff = audioRetention.cutoff(sessionStart: sessionStart) else { return [] }
        return records.indices.filter { records[$0].audioFileName != nil && records[$0].date < cutoff }
    }

    @discardableResult
    private func pruneExpiredAudio(sessionStart: Date) -> Bool {
        let expired = expiredAudio(under: audioRetention, sessionStart: sessionStart)
        for index in expired {
            deleteAudio(records[index])
            records[index].audioFileName = nil
        }
        return !expired.isEmpty
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
    /// between, its refinement), and each write re-encodes every entry kept. The pending write is
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
