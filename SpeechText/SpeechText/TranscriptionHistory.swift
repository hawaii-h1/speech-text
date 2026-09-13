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

        var succeeded: Bool { errorMessage == nil && !outputText.isEmpty }
    }

    /// Where a dictation was delivered, when it went somewhere other than the cursor.
    /// Recorded on failure too: a message the user believes they sent and did not is
    /// exactly the thing that has to be explainable afterwards.
    struct Delivery: Codable, Equatable {
        enum Outcome: String, Codable {
            /// The app completed the send itself (scripted channels).
            case sent
            /// The chat was opened with the text staged; the user finishes it.
            case composed
            case failed
        }

        var channel: String
        var recipientName: String
        var address: String
        var outcome: Outcome
        var errorMessage: String?
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
    /// Optional, so history written before message delivery existed still decodes.
    var delivery: Delivery?

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

    private let ioQueue = DispatchQueue(label: "com.speechtext.history.io")

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

    // MARK: LLM pass

    /// Attaches the result of the AI step to an existing transcription entry.
    func recordRefinement(id: UUID, input: String, output: String, presetName: String?,
                          provider: String, model: String) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: nil
        ))
    }

    /// Records that the AI step was attempted and failed. Worth keeping: the pasted text
    /// silently differs from what the user asked for, and the entry explains why.
    func recordRefinementFailure(id: UUID, input: String, error: String,
                                 provider: String, model: String) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: "", presetName: nil,
            provider: provider, model: model, errorMessage: error
        ))
    }

    func recordDelivery(id: UUID, channel: DeliveryChannel, recipient: RecipientCandidate,
                        outcome: TranscriptionRecord.Delivery.Outcome, error: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            histLog.info("delivery for unknown record \(id.uuidString, privacy: .public) — dropped")
            return
        }
        records[index].delivery = TranscriptionRecord.Delivery(
            channel: channel.displayName,
            recipientName: recipient.displayName,
            address: recipient.address,
            outcome: outcome,
            errorMessage: error
        )
        save()
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
    func recordFailure(error: String, provider: String, locale: String?,
                       duration: TimeInterval, audioURL: URL?) {
        let archived = archive(audioURL: audioURL)
        add(TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .failed,
                                errorMessage: error, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived))
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

    private func save() {
        let snapshot = records
        let url = historyFileURL
        ioQueue.async { [weak self] in
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
    }
}
