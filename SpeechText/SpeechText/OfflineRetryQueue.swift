// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Retrying by itself once the network is back

/// Dictations saved to History for want of a network in *this* session, and when to
/// retry them. Pure logic, in both targets: `OfflineRetry` feeds it the network's state
/// and the retries' results, and does what it answers.
///
/// Memory only, on purpose — "this session" is the decision (#78): a recording archived
/// last week is History's to retry at the user's word, not something to upload the next
/// time the Wi-Fi happens to come up.
///
/// A drain is started by the network *returning* — an unsatisfied → satisfied edge —
/// never by the monitor's first report, which is the current state rather than a
/// change. The one exception is a dictation queued while the network already looks
/// up (the link dropped mid-upload and was back before the failure was written): it is
/// tried once at once, since no edge will ever come for it. It runs one record at a
/// time, oldest first, and a record that finds no network again stops the drain and
/// waits for the next edge, with everything behind it.
struct OfflineRetryQueue {
    enum Result: Equatable {
        /// Transcribed: it leaves the queue, and its text goes to the clipboard.
        case succeeded
        /// No network again: it stays, and so does everything after it.
        case offline
        /// Any other failure, or the record is gone or was retried by the user: it
        /// leaves the queue. History's row already says what happened.
        case dropped
        /// The user is retrying it right now: it stays — should that retry find no
        /// network, the next return still owes it one — and the drain moves on.
        case busy
    }

    /// Oldest first.
    private(set) var pending: [UUID] = []
    private(set) var isDraining = false
    /// The last state the monitor reported; nil before its first report.
    private(set) var networkIsUp: Bool?
    /// Records passed over as `busy` in the running drain.
    private var skipped: Set<UUID> = []

    /// Adds a record. True when a drain should start now: the network already looks up,
    /// so no edge will come to start one.
    mutating func enqueue(_ id: UUID) -> Bool {
        guard !pending.contains(id) else { return false }
        pending.append(id)
        return networkIsUp == true && !isDraining
    }

    /// The monitor's report. True when a drain should start: the network has just come
    /// back and something is waiting for it.
    mutating func networkChanged(isUp: Bool) -> Bool {
        let cameBack = networkIsUp == false && isUp
        networkIsUp = isUp
        return cameBack && !pending.isEmpty && !isDraining
    }

    /// Starts a drain and returns the first record to retry, or nil when there is
    /// nothing to do (or a drain is already running).
    mutating func beginDrain() -> UUID? {
        guard !isDraining, let first = pending.first else { return nil }
        isDraining = true
        return first
    }

    /// Records one retry's result and returns the next record to retry, or nil when the
    /// drain is over — the queue is empty, or the network is gone again.
    mutating func finished(_ id: UUID, _ result: Result) -> UUID? {
        switch result {
        case .succeeded, .dropped:
            pending.removeAll { $0 == id }
        case .busy:
            skipped.insert(id)
        case .offline:
            return endDrain()
        }
        guard let next = pending.first(where: { !skipped.contains($0) }) else { return endDrain() }
        return next
    }

    private mutating func endDrain() -> UUID? {
        isDraining = false
        skipped = []
        return nil
    }
}
