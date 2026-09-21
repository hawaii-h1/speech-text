// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// When the app shows an icon in the Dock (and so in ⌘Tab).
///
/// The app is an `LSUIElement` agent, and an agent's windows have nowhere to be found
/// once another app covers them: no Dock icon, no ⌘Tab entry, no Window menu. The
/// default therefore gives the app a Dock icon for exactly as long as one of its
/// ordinary windows (Settings, History, Debug Log, Presets) is open.
enum DockIconMode: String, CaseIterable, Identifiable {
    case never
    case whileWindowOpen
    case always

    static let `default` = DockIconMode.whileWindowOpen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .whileWindowOpen: return "While a window is open"
        case .always: return "Always"
        }
    }

    static var current: DockIconMode {
        UserDefaults.standard.string(forKey: SettingsKeys.dockIconMode).flatMap(DockIconMode.init) ?? .default
    }
}

extension Notification.Name {
    static let dockIconModeDidChange = Notification.Name("dockIconModeDidChange")
}

/// Switches the activation policy between `.accessory` and `.regular` as windows open
/// and close, or as the setting changes.
///
/// It watches every window rather than being told by each `open…` function, so a
/// window added later cannot forget to report itself.
final class DockIconController {
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        // At `willClose` the window still reports itself visible, so decide once it is gone.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async { self?.update(excluding: closing) }
        })
        observers.append(center.addObserver(forName: .dockIconModeDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        })
        update()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Settings, History and the other titled windows — not the recording overlay, the
    /// status notice or the Record Window, which are panels floating over another app's
    /// work and must not pull a Dock icon in with them. Setup draws its own frame, so it
    /// is borderless, but it is an ordinary window the user leaves for a browser and
    /// comes back to.
    static func hasOpenWindow(excluding excluded: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            window !== excluded
                && !(window is NSPanel)
                && (window.styleMask.contains(.titled) || window is OnboardingWindow)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    private func update(excluding excluded: NSWindow? = nil) {
        let wantsDock: Bool
        switch DockIconMode.current {
        case .never: wantsDock = false
        case .always: wantsDock = true
        case .whileWindowOpen: wantsDock = Self.hasOpenWindow(excluding: excluded)
        }
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        dlog("App", "Dock icon \(wantsDock ? "shown" : "hidden") (\(DockIconMode.current.rawValue))")
    }
}
