// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

/// The inline overlay's shape, as far as placing it is concerned: the strip, and the
/// transcript that grows out of it (from nothing, line by line, up to `maxTranscriptHeight`).
struct OverlayGeometry: Equatable {
    var strip: CGSize
    /// Width of the transcript area; 0 when the recording shows none.
    var transcriptWidth: CGFloat = 0
    var maxTranscriptHeight: CGFloat = 0
    /// Between the strip and the transcript, once there is one.
    var gap: CGFloat = 0

    var showsTranscript: Bool { maxTranscriptHeight > 0 }

    /// The panel's size with the transcript at `transcriptHeight`. The strip sits at the
    /// right-hand end: a transcript wider than the strip reaches out to the left.
    func size(transcriptHeight: CGFloat) -> CGSize {
        guard transcriptHeight > 0 else { return strip }
        return CGSize(width: max(strip.width, transcriptWidth),
                      height: strip.height + gap + transcriptHeight)
    }

    /// The panel at its largest — what placement keeps on screen, so the transcript can
    /// always grow to its full height without leaving it.
    var fullSize: CGSize { size(transcriptHeight: maxTranscriptHeight) }
}

/// Which way the transcript grows from the strip: away from the nearer edge of the screen,
/// so a strip parked at the top can sit at the top.
enum OverlayGrowth: Equatable {
    case up, down
}

/// Where the inline overlay sits on screen. Pure geometry, in both targets: the panel
/// hands in its shape and the screens' visible frames, so a monitor that went away can be
/// tested without one.
///
/// A position is the *strip's* bottom-left corner. The strip is what the user places; the
/// transcript grows out of it, so anchoring anything else would move the strip every time
/// a line of text lands.
enum OverlayPlacement {
    /// The resting inset from a screen's edges — where the default corner is, and where
    /// an edge snaps to.
    static let margin: CGFloat = 20
    /// How close to a resting line a dragged edge has to come to snap onto it.
    static let snapDistance: CGFloat = 18

    struct Placement: Equatable {
        /// The strip's bottom-left corner.
        var strip: CGPoint
        var growth: OverlayGrowth
    }

    /// The panel's frame for a strip at `strip`, with the transcript at `transcriptHeight`.
    static func frame(strip: CGPoint, _ geometry: OverlayGeometry, growth: OverlayGrowth,
                      transcriptHeight: CGFloat) -> CGRect {
        let size = geometry.size(transcriptHeight: transcriptHeight)
        let x = strip.x + geometry.strip.width - size.width
        let y = growth == .up ? strip.y : strip.y - (size.height - geometry.strip.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The default spot: the bottom-right corner of `screen`.
    static func defaultPlacement(_ geometry: OverlayGeometry, in screen: CGRect) -> Placement {
        settled(strip: CGPoint(x: screen.maxX - margin - geometry.strip.width, y: screen.minY + margin),
                geometry, in: screen, snaps: false)
    }

    /// Where the panel opens. `saved` — where the user left the strip — settled onto the
    /// screen holding most of it; the default corner of `main` when nothing was saved, or
    /// when the saved spot is on no screen at all (the monitor it was on is unplugged). Nil
    /// only when there are no screens.
    static func placement(saved: CGPoint?, _ geometry: OverlayGeometry,
                          screens: [CGRect], main: CGRect?) -> Placement? {
        guard let fallback = main ?? screens.first else { return nil }
        guard let saved else { return defaultPlacement(geometry, in: fallback) }

        let strip = CGRect(origin: saved, size: geometry.strip)
        let host = screens
            .map { (screen: $0, overlap: area($0.intersection(strip))) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .screen
        guard let host else { return defaultPlacement(geometry, in: fallback) }
        return settled(strip: saved, geometry, in: host)
    }

    /// The strip proposed at `strip` — by a drag, or a saved spot — made valid on `screen`:
    /// the transcript grows away from the nearer edge, an edge that came within
    /// `snapDistance` of its resting line (or the panel's centre, of the screen's) snaps
    /// onto it, and the whole panel, at its largest, is kept on the screen.
    static func settled(strip: CGPoint, _ geometry: OverlayGeometry, in screen: CGRect,
                        snaps: Bool = true) -> Placement {
        let growth: OverlayGrowth = strip.y + geometry.strip.height / 2 <= screen.midY ? .up : .down
        var full = frame(strip: strip, geometry, growth: growth, transcriptHeight: geometry.maxTranscriptHeight)
        if snaps { full.origin = snapped(full, in: screen) }
        full.origin = clamped(full.origin, size: full.size, in: screen)

        let size = geometry.fullSize
        let settledStrip = CGPoint(x: full.maxX - geometry.strip.width,
                                   y: growth == .up ? full.minY : full.minY + size.height - geometry.strip.height)
        return Placement(strip: settledStrip, growth: growth)
    }

    /// `frame`'s origin, with each axis pulled onto a resting line it came close to.
    static func snapped(_ frame: CGRect, in screen: CGRect) -> CGPoint {
        func snap(_ value: CGFloat, to targets: [CGFloat]) -> CGFloat {
            guard let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }),
                  abs(nearest - value) <= snapDistance else { return value }
            return nearest
        }
        return CGPoint(
            x: snap(frame.minX, to: [screen.minX + margin,
                                     screen.maxX - margin - frame.width,
                                     screen.midX - frame.width / 2]),
            y: snap(frame.minY, to: [screen.minY + margin,
                                     screen.maxY - margin - frame.height]))
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
