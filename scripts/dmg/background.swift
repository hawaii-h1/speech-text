// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the disk image window's background, in the setup window's style: the green glow
// seen through glass, a light card with the title, and the steps pill along the bottom.
//
//   swift background.swift OUT_DIR [APP_ICON.icns]
//
// writes OUT_DIR/background.png (640 × 440) and OUT_DIR/background@2x.png, which
// dmgbuild combines into one Retina-ready image. Drawn rather than kept as a bitmap so a
// change of wording or colour is a change to this file. The colours are the setup's
// (SetupColor, SetupAura and SetupStepsBar in OnboardingChrome.swift).
//
// The geometry has to agree with dmgbuild-settings.py: the two icons are centred at
// APP_CENTER and APPS_CENTER (Finder's coordinates, from the top left).
//
// Two things here are Finder's to decide, not ours:
//
// - How much of the picture shows. The window holds 640 × 420 below its title bar, but a
//   user who keeps Finder's path bar and status bar on (a global setting, which wins over
//   the image's own) sees 56 points less — 364. Everything that says something stays in
//   the top VISIBLE points, and the picture runs on past the window's bottom so that no
//   title bar height ever uncovers Finder's own white under it.
// - The colour of the icons' names: black in light mode, white in dark mode, over
//   whatever is behind them, with no setting for it. So the icons stand on the glow, not
//   on the card, and the glow is kept mid-tone where the names are — checked below on the
//   rendered pixels, so a change of colour that would lose them in either mode fails here
//   rather than on someone's desktop.

import AppKit

let WIDTH: CGFloat = 640
let HEIGHT: CGFloat = 440
let VISIBLE: CGFloat = 364
let APP_CENTER = CGPoint(x: 170, y: 222)
let APPS_CENTER = CGPoint(x: 470, y: 222)
let ICON: CGFloat = 128
/// Where Finder writes each icon's name, 13-point, under the icon.
let LABEL_BAND = (top: APP_CENTER.y + ICON / 2 + 4, height: CGFloat(18))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// SetupColor
let brandDeep: UInt32 = 0x0D3A25
let brand: UInt32 = 0x14543A
let phosphor: UInt32 = 0x61C58C
let confirmation: UInt32 = 0x30D158
let card: UInt32 = 0xFBFBFB

func glow(_ cg: CGContext, _ hex: UInt32, _ alpha: CGFloat, at center: CGPoint, radius: CGFloat) {
    let colors = [color(hex, alpha).cgColor, color(hex, 0).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          tracking: CGFloat = 0, lineSpacing: CGFloat = 0, alignment: NSTextAlignment = .left) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = lineSpacing
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
        .paragraphStyle: paragraph,
    ])
}

func draw(icon: NSImage?, into rep: NSBitmapImageRep) {
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    // Finder's coordinates run from the top left; so does everything below.
    cg.translateBy(x: 0, y: HEIGHT)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // The glow (SetupAura), still: the app's greens pooled under the glass.
    color(0x2F8A5E).setFill()
    CGRect(x: 0, y: 0, width: WIDTH, height: HEIGHT).fill()
    glow(cg, phosphor, 0.7, at: CGPoint(x: 70, y: 170), radius: 240)
    glow(cg, 0x1F8A5A, 0.9, at: CGPoint(x: 560, y: 150), radius: 280)
    glow(cg, confirmation, 0.35, at: CGPoint(x: 470, y: 330), radius: 220)
    glow(cg, 0x2F9E67, 0.8, at: CGPoint(x: 300, y: 420), radius: 240)
    glow(cg, brandDeep, 0.3, at: CGPoint(x: 320, y: 225), radius: 190)
    glow(cg, brand, 0.5, at: CGPoint(x: 640, y: 440), radius: 260)
    // The glass over it (SetupFrame's light-mode wash, lighter at the top left).
    NSGradient(colors: [color(0xFFFFFF, 0.24), color(0xFFFFFF, 0.06), color(0xFFFFFF, 0.14)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: 0, y: 0, width: WIDTH, height: HEIGHT), angle: -35)

    // The card, as on every setup step.
    let cardRect = CGRect(x: 14, y: 12, width: WIDTH - 28, height: 124)
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 18, yRadius: 18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.12)
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.shadowBlurRadius = 8
    shadow.set()
    color(card).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x000000, 0.1).setStroke()
    let rim = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.25, dy: 0.25), xRadius: 18, yRadius: 18)
    rim.lineWidth = 0.5
    rim.stroke()

    // The Welcome step's opening: the icon, a title, the lead.
    var textX = cardRect.minX + 28
    if let icon {
        let iconRect = CGRect(x: cardRect.minX + 24, y: cardRect.minY + 30, width: 64, height: 64)
        NSGraphicsContext.saveGraphicsState()
        let iconShadow = NSShadow()
        iconShadow.shadowColor = color(0x000000, 0.18)
        iconShadow.shadowOffset = NSSize(width: 0, height: -3)
        iconShadow.shadowBlurRadius = 3
        iconShadow.set()
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        textX = iconRect.maxX + 20
    }
    text("Drag SpeechText to Applications", size: 26, weight: .semibold,
         color: color(0x000000, 0.88), tracking: -26 * 0.03)
        .draw(in: CGRect(x: textX, y: cardRect.minY + 26, width: cardRect.maxX - textX - 20, height: 34))
    text("Then open it from Applications — setup walks you through the rest.\nAfter that, this disk image is no longer needed.",
         size: 13.5, weight: .regular, color: color(0x000000, 0.56), lineSpacing: 3)
        .draw(in: CGRect(x: textX, y: cardRect.minY + 64, width: cardRect.maxX - textX - 20, height: 44))

    // The drag, as a run of dots — the record window's dot-matrix display.
    let startX = APP_CENTER.x + ICON / 2 + 36, endX = APPS_CENTER.x - ICON / 2 - 36
    let y = APP_CENTER.y - 6
    let pitch: CGFloat = 9, dot: CGFloat = 5
    func dotAt(_ p: CGPoint, _ alpha: CGFloat) {
        color(0xFFFFFF, alpha).setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)).fill()
    }
    let count = Int(((endX - startX) / pitch).rounded(.down))
    for index in 0...count {
        dotAt(CGPoint(x: endX - CGFloat(count - index) * pitch, y: y),
              0.35 + 0.6 * CGFloat(index) / CGFloat(max(count, 1)))
    }
    for step in 1...3 {
        let offset = CGFloat(step) * pitch * 0.8
        dotAt(CGPoint(x: endX - offset, y: y - offset), 0.95)
        dotAt(CGPoint(x: endX - offset, y: y + offset), 0.95)
    }

    // The steps pill (SetupStepsBar): where this is in the whole install.
    let steps = ["Drag to Applications", "Open SpeechText", "Setup"]
    let fonts = steps.indices.map { NSFont.systemFont(ofSize: 12, weight: $0 == 0 ? .semibold : .regular) }
    let widths = steps.indices.map { (steps[$0] as NSString).size(withAttributes: [.font: fonts[$0]]).width }
    let dotSize: CGFloat = 9, dotGap: CGFloat = 6, connector: CGFloat = 36, padding: CGFloat = 16
    let pillWidth = padding * 2 + widths.reduce(0, +) + CGFloat(steps.count) * (dotSize + dotGap)
        + CGFloat(steps.count - 1) * (connector + 16)
    let pill = CGRect(x: (WIDTH - pillWidth) / 2, y: VISIBLE - 44, width: pillWidth, height: 32)
    NSGraphicsContext.saveGraphicsState()
    let pillShadow = NSShadow()
    pillShadow.shadowColor = color(0x000000, 0.08)
    pillShadow.shadowOffset = NSSize(width: 0, height: -2)
    pillShadow.shadowBlurRadius = 4
    pillShadow.set()
    color(0xFFFFFF, 0.9).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 16, yRadius: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x000000, 0.1).setStroke()
    let pillRim = NSBezierPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), xRadius: 16, yRadius: 16)
    pillRim.lineWidth = 0.5
    pillRim.stroke()

    var x = pill.minX + padding
    for (index, step) in steps.enumerated() {
        let current = index == 0
        let dotRect = CGRect(x: x, y: pill.midY - dotSize / 2, width: dotSize, height: dotSize)
        if current {
            color(phosphor, 0.35).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -3, dy: -3)).fill()
            color(brand).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            color(0x000000, 0.32).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        x = dotRect.maxX + dotGap
        let label = text(step, size: 12, weight: current ? .semibold : .regular,
                         color: color(0x000000, current ? 0.88 : 0.56))
        label.draw(at: CGPoint(x: x, y: pill.midY - label.size().height / 2))
        x += widths[index]
        if index < steps.count - 1 {
            let line = CGRect(x: x + 8, y: pill.midY - 0.5, width: connector, height: 1)
            if current {
                NSGradient(starting: color(brand), ending: color(0x000000, 0.1))!.draw(in: line, angle: 0)
            } else {
                color(0x000000, 0.1).setFill()
                line.fill()
            }
            x = line.maxX + 8
        }
    }
}

/// The mean relative luminance (WCAG) of a band of the rendered picture.
func luminance(of rep: NSBitmapImageRep, in rect: CGRect, scale: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    var total: CGFloat = 0, count: CGFloat = 0
    for py in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
        for px in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            total += 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
            count += 1
        }
    }
    return total / max(count, 1)
}

func render(scale: CGFloat, icon: NSImage?, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(WIDTH * scale), pixelsHigh: Int(HEIGHT * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: WIDTH, height: HEIGHT)
    NSGraphicsContext.saveGraphicsState()
    draw(icon: icon, into: rep)
    NSGraphicsContext.restoreGraphicsState()

    // Black on it and white on it must both reach 3:1 — relative luminance 0.10 to 0.30.
    for center in [APP_CENTER, APPS_CENTER] {
        let band = CGRect(x: center.x - 60, y: LABEL_BAND.top, width: 120, height: LABEL_BAND.height)
        let l = luminance(of: rep, in: band, scale: scale)
        guard (0.10...0.30).contains(l) else {
            FileHandle.standardError.write("background.swift: under the icon at x=\(Int(center.x)) the luminance is \(String(format: "%.3f", l)); Finder's black or white names would not read on it (needs 0.10–0.30)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count) else {
    FileHandle.standardError.write("usage: swift background.swift OUT_DIR [APP_ICON.icns]\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
let icon = arguments.count == 3 ? NSImage(contentsOfFile: arguments[2]) : nil
try render(scale: 1, icon: icon, to: out.appendingPathComponent("background.png"))
try render(scale: 2, icon: icon, to: out.appendingPathComponent("background@2x.png"))
