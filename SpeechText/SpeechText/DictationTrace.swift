// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One inline dictation as the app saw it: the provider's events as they arrived, the
/// stop, the batch fallback's answer, the rewrite, and every paste. Written by
/// `DictationTraceRecorder` when `recordDictationTraces` is on, and read back by the
/// test target's `DictationReplay`, which plays the events through the delivery code
/// again — so a dictation that went wrong once becomes a test that stays.
///
/// Flat and hand-editable on purpose: after reviewing a trace, set `expectedDocument` to
/// what the document *should* hold, and the replay checks that as well.
struct DictationTrace: Codable, Equatable {
    struct Setup: Codable, Equatable {
        var aiMode = false
        var aiDraft = false
        var removesDisfluencies = true
        /// Optional so a trace recorded before the setting existed still decodes; nil
        /// replays as `.emDash`, which is what those dictations were pasted with.
        var dashStyle: DashStyle?
        /// The target app's name — for the reader; the replay goes by `probe`.
        var app: String?
        var probe = Probe()
    }

    /// `AXTextProbe`, as recorded.
    struct Probe: Codable, Equatable {
        var valueReadable = false
        var rangeReadable = false
        var rangeReadsBack = false
    }

    struct Event: Codable, Equatable {
        enum Kind: String, Codable {
            /// The provider's partial, as it arrived — before any merging.
            case partial
            /// The provider's committed segment, as it arrived.
            case committed
            /// The stream broke; `error` says how.
            case streamFailed
            /// A span was ready, but the target app was not in front.
            case targetNotInFront
            /// A span delivery was pasted; `landing` says what could be read back.
            case paste
            /// The user stopped the recording.
            case stop
            /// The batch upload's answer after the stream broke or came back empty.
            case fallback
            /// The finalizing pass (or the AI draft's replacement) ran; `applied` is its result.
            case correction
            /// The LLM's rewrite in `text`, or its failure in `error`.
            case refinement
            /// The stop's own paste.
            case stopPaste
        }

        enum Landing: String, Codable {
            /// The app holds exactly what was pasted, where it was pasted.
            case exact
            /// The landing could not be read.
            case unknown
            /// The app stored something other than what was pasted.
            case different
        }

        /// Seconds since the recording started.
        var t: Double
        var kind: Kind
        var text: String?
        var error: String?
        var landing: Landing?
        var applied: Bool?
    }

    var version = 1
    var recordedAt: Date
    var setup: Setup
    var events: [Event] = []
    /// Written by hand after reviewing the trace. Nil: the replay only checks that the app
    /// still pastes what it pasted when the trace was recorded.
    var expectedDocument: String?
    var note: String?

    /// Only a streamed dictation can be replayed: the other tiers have no events.
    var isReplayable: Bool {
        events.contains { [.partial, .committed, .streamFailed, .fallback].contains($0.kind) }
    }

    static func decode(_ data: Data) throws -> DictationTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DictationTrace.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Collects one dictation's `DictationTrace`. Main thread only.
final class DictationTraceRecorder {
    /// The dictation being traced, or nil — which is always, unless the setting is on.
    static var current: DictationTraceRecorder?

    private var trace: DictationTrace
    private let started: Date

    init(setup: DictationTrace.Setup, now: Date = Date()) {
        trace = DictationTrace(recordedAt: now, setup: setup)
        started = now
    }

    static func record(_ kind: DictationTrace.Event.Kind, text: String? = nil, error: String? = nil,
                       landing: DictationTrace.Event.Landing? = nil, applied: Bool? = nil) {
        current?.record(kind, text: text, error: error, landing: landing, applied: applied)
    }

    func record(_ kind: DictationTrace.Event.Kind, text: String? = nil, error: String? = nil,
                landing: DictationTrace.Event.Landing? = nil, applied: Bool? = nil) {
        let t = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        trace.events.append(.init(t: t, kind: kind, text: text, error: error, landing: landing, applied: applied))
    }

    /// Writes the trace into `directory` as `<date>.json` and returns its URL — nil when
    /// there is nothing to replay (Apple or a plain batch upload) or the write failed.
    func write(into directory: URL) -> URL? {
        guard trace.isReplayable else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent(formatter.string(from: trace.recordedAt) + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try trace.encoded().write(to: url, options: .atomic)
            return url
        } catch {
            dlog("Trace", "could not write the trace: \(error.localizedDescription)")
            return nil
        }
    }
}
