// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

/// Where the inline overlay sits on screen. Pure geometry, in both targets: the panel
/// hands in its size and the screens' visible frames, so a monitor that went away can be
/// tested without one.
///
/// Positions are the panel's *bottom-left* corner. The panel grows upward when it shows
/// the transcript, and anchoring it at the bottom keeps the strip where the user put it
/// instead of jumping by the height of the text area.
enum OverlayPlacement {
    /// How far the default corner is inset from the screen's edges.
    static let margin: CGFloat = 20

    /// The default spot: the bottom-right corner of `screen`.
    static func defaultOrigin(size: CGSize, in screen: CGRect) -> CGPoint {
        clamped(CGPoint(x: screen.maxX - margin - size.width, y: screen.minY + margin),
                size: size, in: screen)
    }

    /// Where a panel of `size` goes. `saved` — where the user dragged it — moved as little
    /// as needed to be whole on the screen it is mostly on; the default corner of `main`
    /// when nothing was saved, or when the saved spot is on no screen at all (the monitor
    /// it was on has been unplugged). Nil only when there are no screens.
    static func origin(saved: CGPoint?, size: CGSize, screens: [CGRect], main: CGRect?) -> CGPoint? {
        guard let fallback = main ?? screens.first else { return nil }
        guard let saved else { return defaultOrigin(size: size, in: fallback) }

        let frame = CGRect(origin: saved, size: size)
        let host = screens
            .map { (screen: $0, overlap: area($0.intersection(frame))) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .screen
        guard let host else { return defaultOrigin(size: size, in: fallback) }
        return clamped(saved, size: size, in: host)
    }

    /// `origin` moved inside `screen`. A panel bigger than the screen keeps its bottom-left
    /// corner on it.
    static func clamped(_ origin: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    // MARK: Storing it

    /// `"x,y"`, whole points — `SettingsKeys.overlayOrigin`.
    static func encode(_ origin: CGPoint) -> String {
        "\(Int(origin.x.rounded())),\(Int(origin.y.rounded()))"
    }

    /// Nil for an empty or unreadable value, which means the default corner.
    static func decode(_ stored: String) -> CGPoint? {
        let parts = stored.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
