// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle

/// **The only file that imports Sparkle** — the second and last third-party framework in
/// the app, and the same arrangement `LocalWhisperRuntime.swift` has with WhisperKit:
/// everything around it is Apple frameworks, so the standalone test bundle keeps
/// building and replacing the updater is one file rather than a rewrite.
///
/// SpeechText ships outside the App Store, so nothing updates it for us. Sparkle reads
/// an *appcast* — a small XML feed published as an asset of each GitHub release — finds
/// the newest version there, and (after the user agrees) downloads the disk image,
/// replaces the app and restarts it. Every update is signed with an EdDSA key that is
/// ours alone, separate from the Apple certificate: that is what makes the download
/// trustworthy even if the Developer ID team changes, which is exactly what converting
/// the Apple account to an organization would do.
///
/// Both halves of that setup live in `Info.plist` — `SUFeedURL` and `SUPublicEDKey` —
/// and `docs/releasing.md` says where the key comes from.
///
/// Not actor-isolated, like the rest of the app's AppKit glue: every caller — the status
/// menu's actions, the Settings form — is already on the main thread, which is where
/// Sparkle requires its updater to be used.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let controller: SPUStandardUpdaterController?

    /// Whether this build can check for updates at all. False in a source checkout that
    /// has no signing key yet: Sparkle's own answer to a missing key is a modal alert a
    /// second after launch, on every launch, which is worse than a menu item that isn't
    /// there. See `docs/releasing.md` for generating the key.
    var isConfigured: Bool { controller != nil }

    /// The feed the app follows, for the Debug Log and for the settings row's subtitle.
    var feedURL: String? { Self.infoValue("SUFeedURL") }

    /// Sparkle checks once a day on its own. Off in a development build — see
    /// `isDevelopmentBuild` — and the user can switch it off in Settings.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// When the last check happened, so Settings can say something more useful than a
    /// bare switch.
    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// A build that was not made by `scripts/rebuild.sh` or the release workflow: no
    /// commit stamped into `Info.plist`, and the build number Xcode leaves behind is 1.
    /// Such a build would see *every* release as newer than itself, and letting Sparkle
    /// replace a bundle sitting in DerivedData is not a thing anyone wants to debug.
    /// The menu item still works, so an update can be exercised deliberately.
    static var isDevelopmentBuild: Bool { AppVersion.commit == nil || AppVersion.build == "1" }

    private init() {
        guard Self.infoValue("SUFeedURL") != nil, Self.infoValue("SUPublicEDKey") != nil else {
            controller = nil
            dlog("Update", "no SUFeedURL/SUPublicEDKey in Info.plist — updates are off in this build")
            return
        }
        // Sparkle's standard controller owns the updater, the update windows and the
        // background schedule; starting it here means the first check happens on its own.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        if Self.isDevelopmentBuild {
            controller?.updater.automaticallyChecksForUpdates = false
        }
        dlog("Update", "updater started (feed \(feedURL ?? "?"), automatic \(checksAutomatically))")
    }

    /// The menu item. The app is an agent with no windows of its own, so nothing brings
    /// it forward when Sparkle opens one — without this the "an update is available"
    /// window can appear behind whatever the user was working in.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    /// An `Info.plist` string that is actually a value, with the same rule `AppVersion`
    /// uses: an unsubstituted `$(...)` placeholder is not one.
    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
