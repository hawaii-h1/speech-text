import Foundation
import os.log

private let histLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoicePeter",
                             category: "History")

// MARK: - Record

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case success
        case empty
        case failed
    }

    let id: UUID
    let date: Date
    var text: String
    var status: Status
    var errorMessage: String?
    let provider: String
    let locale: String?
    let duration: TimeInterval
    /// Filename (not a full path — the container may move) of the archived WAV kept
    /// so a failed transcription can be retried instead of being lost.
    var audioFileName: String?

    var isRetryable: Bool { audioFileName != nil && status != .success }
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

    private let ioQueue = DispatchQueue(label: "com.voicepeter.history.io")

    private init() {
        load()
        pruneExpiredAudio()
    }

    // MARK: Paths

    private var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("VoicePeter", isDirectory: true)
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

    func recordSuccess(text: String, provider: String, locale: String?, duration: TimeInterval) {
        add(TranscriptionRecord(id: UUID(), date: Date(), text: text, status: .success,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: nil))
    }

    /// Records a failure and *keeps* the audio so the user can retry it. Passing the temp
    /// WAV here transfers ownership — do not call `AudioBufferWriter.cleanup` on it after.
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

    /// Move a temp WAV into the archive. Returns the stored filename, or nil if there
    /// was no audio or the move failed (in which case the record is still kept).
    private func archive(audioURL: URL?) -> String? {
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        ensureDirectories()

        let filename = "\(UUID().uuidString).wav"
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
