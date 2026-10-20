// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - How long a realtime segment stayed open

/// How long the realtime server kept one segment open — from the audio it was sent, not
/// the clock, so a replay that feeds a minute of audio in a millisecond measures what a
/// live dictation does.
///
/// Scribe Realtime closes a segment only after `STTTuning.vadSilenceThresholdSeconds` of
/// silence, and someone reading or dictating a paragraph rarely pauses that long. A
/// segment left open for half a minute is where the model began writing text that is not
/// in the audio — a schedule nobody read out, one phrase fifteen times — and the stop
/// pasted it. Closing segments from the client was measured and rejected: the reply to
/// each client commit itself often ended in an invented sentence. So the stream is
/// trusted only while no segment ran longer than `limit`; past it, the stop takes the
/// upload's answer, as it does after an outage.
struct OpenSegmentClock {
    /// The socket's rate: 16-bit mono, so two bytes a sample.
    let sampleRate: Double

    private var openBytes = 0
    private var longestClosedBytes = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Audio sent to the socket.
    mutating func feed(byteCount: Int) {
        openBytes += byteCount
    }

    /// The server closed the segment — a `committed_transcript` arrived — or a new socket
    /// opened one of its own.
    mutating func segmentClosed() {
        longestClosedBytes = max(longestClosedBytes, openBytes)
        openBytes = 0
    }

    /// The longest segment so far, the one still open included.
    var longestSeconds: Double {
        Double(max(longestClosedBytes, openBytes)) / (sampleRate * 2)
    }

    /// Did any segment run longer than `limit` seconds? Never, with no limit.
    func exceeded(_ limit: Double?) -> Bool {
        guard let limit else { return false }
        return longestSeconds > limit
    }
}
