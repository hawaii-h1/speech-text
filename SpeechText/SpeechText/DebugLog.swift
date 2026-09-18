// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os.log

@Observable
final class DebugLog {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 1000
    /// Trimming is O(n) in the whole buffer, so it is paid once per `trimSlack` entries
    /// rather than on every log line: the array is allowed to run over before it is cut
    /// back to `maxEntries`.
    private let trimSlack = 100
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                                category: "Debug")

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    func log(_ category: String, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")

        if Thread.isMainThread {
            appendEntry(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendEntry(entry)
            }
        }
    }

    private func appendEntry(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries + trimSlack {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func formatted() -> String {
        entries.map {
            "\(Self.dateFormatter.string(from: $0.timestamp)) [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }
}

/// Shorthand for logging from anywhere.
func dlog(_ category: String, _ message: String) {
    DebugLog.shared.log(category, message)
}
