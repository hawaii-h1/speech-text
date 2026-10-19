// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

// MARK: - Third-party notices (Resources/ThirdPartyNotices.txt)

/// The licences the app ships must name the versions it is built with: a package
/// updated without re-running scripts/third-party-notices.sh would ship another
/// version's licence, or none for code it newly carries.
final class ThirdPartyNoticesTests: XCTestCase {
    /// Pinned, but not linked into the app — WhisperKit's command-line tool pulls it in.
    private let notShipped: Set<String> = ["swift-argument-parser"]

    func testEveryShippedPackageIsListedAtItsPinnedVersion() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolved = repository.appendingPathComponent(
            "SpeechText/SpeechText.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let notices = try String(contentsOf: repository.appendingPathComponent(
            "SpeechText/SpeechText/Resources/ThirdPartyNotices.txt"), encoding: .utf8)
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String? }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        let pins = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolved)).pins
        XCTAssertFalse(pins.isEmpty)
        for pin in pins where !notShipped.contains(pin.identity) {
            let version = try XCTUnwrap(pin.state.version, pin.identity)
            XCTAssertTrue(notices.contains("\n\(pin.identity) \(version) — "),
                          "\(pin.identity) \(version) is not in ThirdPartyNotices.txt — run scripts/third-party-notices.sh")
        }
    }
}
