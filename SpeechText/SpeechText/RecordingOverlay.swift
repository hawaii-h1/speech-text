// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - Inline overlay

/// The strip that floats in a corner of the screen while an inline dictation is running,
/// and — for a streaming recording — the transcript being built above it.
///
/// It has no controls of its own by design — the hotkey starts and stops it. The only
/// affordance is a cancel button, kept beside the display rather than over it.
///
/// The transcript is why this exists as more than a meter: a streaming provider closes a
/// sentence on a short pause and reopens it a moment later ("…зробимо. Потім" →
/// "…зробимо, потім"), and only a surface we own can show that correction happening.
/// The text is pasted once, at the stop, in its final form.
///
/// Both skins live here rather than in separate files: they show the same states
/// (listening, working, AI, the transcript) from the same inputs, and keeping them in
/// one place is what stops one of them from quietly falling behind.
struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let isPreparing: Bool
    /// Recolours the display so an LLM-processed dictation is obvious at a glance.
    var isAIMode: Bool = false
    /// Draw the transcript. It takes whatever height the panel gives it — the panel grows
    /// it from nothing towards `onTranscriptHeight`'s answer, see `RecordingOverlayPanel`.
    var showsTranscript: Bool = false
    /// The strip is at the top and the transcript grows down from it.
    var growsDown: Bool = false
    /// The transcript's height right now — animated by the panel, 0 until the first word.
    var transcriptHeight: CGFloat = 0
    /// What the provider has committed, all segments — drawn at full brightness.
    var settledText: String = ""
    /// The partial it may still take back — drawn dimmer, after the settled text.
    var movingText: String = ""
    /// The height the transcript would like: its text and padding, 0 before the first word.
    var onTranscriptHeight: (CGFloat) -> Void = { _ in }
    let onCancel: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral

    @State private var isHoveringCancel = false
    /// The text's own height, for the fade that shows lines have scrolled off the top.
    @State private var textHeight: CGFloat = 0

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }
    private var accent: Color { isAIMode ? Semantic.ai : AccentColor.meter(accentHex) }
    private var isBusy: Bool { isLoading || isPreparing }
    private var hasText: Bool { !settledText.isEmpty || !movingText.isEmpty }

    var body: some View {
        // The panel is sized from outside, frame by frame while the transcript grows, so
        // the view fills it rather than proposing a size of its own.
        Group {
            switch skin {
            case .minimal: minimalBody
            case .techno: technoBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: growsDown ? .top : .bottom)
    }

    // MARK: Transcript

    /// The settled text, then the partial, at two brightnesses — the same boundary the
    /// Record Window's glass draws.
    private func transcriptText(base: Color) -> Text {
        var text = Text(verbatim: "")
        if !settledText.isEmpty {
            text = text + Text(verbatim: settledText).foregroundStyle(base.opacity(0.9))
        }
        if !movingText.isEmpty {
            let lead = settledText.isEmpty ? "" : " "
            text = text + Text(verbatim: lead + movingText).foregroundStyle(base.opacity(0.45))
        }
        return text
    }

    /// The transcript, pinned to its newest line: the text is laid out at its full height
    /// and the area shows its bottom, so as the panel grows the older lines come into view
    /// above, and once it stops growing they slide off the top under a fade.
    private func transcript(base: Color, font: Font, horizontal: CGFloat,
                            top: CGFloat, bottom: CGFloat) -> some View {
        transcriptText(base: base)
            .font(font)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: proxy.size.height)
                }
            }
            .padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .mask {
                GeometryReader { proxy in
                    let overflows = textHeight + top + bottom > proxy.size.height + 1
                    LinearGradient(stops: [.init(color: overflows ? .clear : .black, location: 0),
                                           .init(color: .black, location: overflows ? 0.3 : 0)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .onPreferenceChange(TranscriptHeightKey.self) { height in
                textHeight = height
                onTranscriptHeight(hasText ? (height + top + bottom).rounded(.up) : 0)
            }
            .onChange(of: hasText) {
                onTranscriptHeight(hasText ? (textHeight + top + bottom).rounded(.up) : 0)
            }
    }

    // MARK: Minimal

    /// One piece of glass: the strip is a capsule, and the glass keeps the capsule's
    /// radius as the transcript grows out of it, so the strip's ends stay its corners.
    private var minimalShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin.overlayStripSize.height / 2, style: .continuous)
    }

    private var minimalBody: some View {
        VStack(spacing: 0) {
            if growsDown { minimalStrip }
            if showsTranscript {
                // Kept in the hierarchy at zero height too: it is what measures the text.
                // Its height is whatever the window leaves above the strip, so glass and
                // window edge move together on every frame of the growth.
                transcript(base: .primary, font: .system(size: 13), horizontal: 16,
                           top: growsDown ? 6 : 12, bottom: growsDown ? 12 : 6)
                    .frame(maxHeight: transcriptHeight > 0 ? .infinity : 0)
            }
            if !growsDown { minimalStrip }
        }
        .background(.ultraThinMaterial)
        .clipShape(minimalShape)
        .overlay {
            // Only AI mode gets an outline; a plain dictation is meant to be a quiet
            // sliver of glass over whatever the user is working in.
            if isAIMode {
                minimalShape.stroke(accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    private var minimalStrip: some View {
        HStack(spacing: 10) {
            // What kind of dictation this is, where the language badge used to be: the
            // language rarely changes and had to be read, the AI rewrite changes what gets
            // pasted and has to be noticed.
            Image(systemName: isAIMode ? "sparkles" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isAIMode ? accent : accent.opacity(0.55))
                .frame(width: 24, height: 24)
                .help(isAIMode ? "AI dictation — rewritten before it is pasted" : "Dictation")

            WaveformBarsView(
                barLevels: barLevels,
                isLoading: isLoading,
                isPreparing: isPreparing,
                spacing: 6,
                minBarHeight: 4,
                maxBarHeight: 26,
                barColor: accent
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(isHoveringCancel ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(.primary.opacity(isHoveringCancel ? 0.12 : 0))
                    )
                    .scaleEffect(isHoveringCancel ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .help("Cancel (nothing is pasted)")
            .pointingHandCursor { isHoveringCancel = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHoveringCancel)
        }
        .padding(.horizontal, 12)
        .frame(height: skin.overlayStripSize.height)
        .background {
            // Once there is text, the strip reads as a bar of its own within the glass.
            Capsule().fill(.primary.opacity(showsTranscript && hasText ? 0.07 : 0))
                .animation(.easeInOut(duration: 0.25), value: hasText)
        }
    }

    // MARK: Techno

    /// 8 rows at the design's 7pt pitch, and enough columns to overrun the glass at
    /// both ends — the design clips the dot mask rather than framing it.
    private static let technoColumns = 16
    private static let technoRows = 8
    private static let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private static let transcriptGlass = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var technoBody: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if growsDown { technoStrip }
            if showsTranscript {
                // Kept in the hierarchy at zero height too: it is what measures the text.
                let geometry = skin.overlayGeometry(showsTranscript: true)
                technoTranscript
                    .frame(width: geometry.transcriptWidth)
                    .frame(maxHeight: transcriptHeight > 0 ? .infinity : 0)
                    .opacity(transcriptHeight > 0 ? 1 : 0)
                    // Until it has a height the panel is only as wide as the strip; the glass
                    // overhangs it invisibly rather than being laid out narrower — it is
                    // measuring the text, and at the wrong width it would measure wrong.
                    .frame(width: transcriptHeight > 0 ? geometry.transcriptWidth : geometry.strip.width,
                           alignment: .trailing)
                    .padding(growsDown ? .top : .bottom, transcriptHeight > 0 ? geometry.gap : 0)
            }
            if !growsDown { technoStrip }
        }
    }

    /// The transcript on a glass of its own, phosphor on black like the Record Window's.
    private var technoTranscript: some View {
        ZStack {
            Self.transcriptGlass.fill(TechnoSkin.screen)
            transcript(base: isAIMode ? TechnoSkin.aiText : TechnoSkin.phosphorText,
                       font: .system(size: 12, design: .monospaced),
                       horizontal: 16, top: 12, bottom: 12)
            InnerShadow(shape: Self.transcriptGlass, width: 6.6, blur: 3.3)
            InnerShadow(shape: Self.transcriptGlass, width: 4, blur: 2,
                        offset: CGSize(width: 0, height: -1))
        }
        .clipShape(Self.transcriptGlass)
    }

    private var technoStrip: some View {
        HStack(spacing: 6) {
            ZStack {
                Self.glass.fill(TechnoSkin.screen)

                PixelWaveform(
                    levels: barLevels,
                    columns: Self.technoColumns,
                    rows: Self.technoRows,
                    mode: isBusy ? .busy : .level,
                    palette: isAIMode ? .ai : .phosphor
                )

                // The design's inset shadow — it seats the glass into the panel edge.
                InnerShadow(shape: Self.glass, width: 6.6, blur: 3.3)
                InnerShadow(shape: Self.glass, width: 4, blur: 2,
                            offset: CGSize(width: 0, height: -1))
            }
            .frame(width: 100, height: 56)
            .clipShape(Self.glass)

            // Cancel is a button *of the device*: the same moulded plastic in the same
            // milled recess as the record window's rail, so the two techno surfaces
            // read as one machine. It is never drawn on the glass — the display is for
            // the voice, and a disc floating on it made the screen look clickable.
            ButtonRail {
                PlasticButton(
                    systemImage: "xmark",
                    help: "Cancel (nothing is pasted)",
                    action: onCancel
                )
            }
        }
        .frame(width: skin.overlayStripSize.width, height: skin.overlayStripSize.height)
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Status Overlay

/// Transient notice shown after a recording ends without usable text — a provider
/// error, or silence. Without this the inline flow fails completely silently.
struct StatusOverlayView: View {
    let icon: String
    let title: String
    let detail: String?
    let tint: Color
    let onTap: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @State private var isHovering = false

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin == .techno ? 18 : 16, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: skin == .techno ? .light : .medium))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(titleColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background {
            switch skin {
            case .minimal: Rectangle().fill(.ultraThinMaterial)
            case .techno: shape.fill(TechnoSkin.screen)
            }
        }
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
        .clipShape(shape)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .pointingHandCursor { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var titleColor: Color {
        skin == .techno ? TechnoSkin.phosphorText : .primary
    }

    private var detailColor: Color {
        skin == .techno ? TechnoSkin.phosphorText.opacity(0.6) : .secondary
    }

    private var borderColor: Color {
        skin == .techno
            ? TechnoSkin.phosphor.opacity(isHovering ? 0.35 : 0.14)
            : .primary.opacity(isHovering ? 0.25 : 0.10)
    }
}

final class StatusOverlayPanel: NSPanel {
    static let panelWidth: CGFloat = 340

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true

        positionWhereTheOverlayWas()
    }

    /// The notice takes the recording overlay's place — it usually replaces it on screen —
    /// so it opens at the overlay's spot, kept whole on the screen like the overlay is.
    private func positionWhereTheOverlayWas() {
        // Right-aligned with where the strip was, the way the default corner is.
        let strip = AppSkin.current.overlayStripSize
        let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
            .map { CGPoint(x: $0.x + strip.width - frame.width, y: $0.y) }
        guard let placed = OverlayPlacement.placement(saved: saved, OverlayGeometry(strip: frame.size),
                                                      screens: NSScreen.screens.map(\.visibleFrame),
                                                      main: NSScreen.main?.visibleFrame) else { return }
        setFrameOrigin(placed.strip)
    }
}

// MARK: - Panel

/// What the panel tells the view it hosts: which way the transcript grows, and how tall it
/// is on this frame of its animation.
@Observable
final class OverlayLayout {
    var growsDown = false
    var transcriptHeight: CGFloat = 0
}

/// The inline overlay's window.
///
/// It opens where the user last left it — the bottom-right corner until they move it —
/// and is never anywhere a screen does not show all of it. The user drags it by any part
/// that is not a button; the drag is the panel's own rather than AppKit's, so it can be
/// held on screen *while* it moves (edges stop at the screen's, and snap onto a resting
/// line `OverlayPlacement.margin` in from them as they come near) instead of being
/// corrected after the mouse is let go. The saved spot is also re-checked on every show,
/// skin change and display change, so an unplugged monitor cannot strand it.
///
/// For a streaming recording the transcript grows out of the strip: the view reports the
/// height its text wants, and the panel eases towards it on the display's clock, resizing
/// the window around the strip each frame. The window is always exactly as big as what is
/// drawn — a taller, partly transparent window would sit on top of whatever the user is
/// working in.
final class RecordingOverlayPanel: NSPanel {
    let layout = OverlayLayout()

    private var geometry: OverlayGeometry
    private var placement: OverlayPlacement.Placement
    private var observers: [NSObjectProtocol] = []

    /// Where the transcript is easing to, and the clock driving it.
    private var targetTranscriptHeight: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?

    /// A press that may become a drag: where the mouse and the strip were.
    private var pressStart: (mouse: CGPoint, strip: CGPoint)?
    private var isDragging = false

    init(showsTranscript: Bool = false) {
        geometry = AppSkin.current.overlayGeometry(showsTranscript: showsTranscript)
        placement = OverlayPlacement.Placement(strip: .zero, growth: .up)
        super.init(
            contentRect: NSRect(origin: .zero, size: geometry.strip),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The drag is handled in `sendEvent`, where it can be kept on screen as it happens.
        isMovableByWindowBackground = false
        hasShadow = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .skinDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.geometry = AppSkin.current.overlayGeometry(showsTranscript: self.geometry.showsTranscript)
            self.placeAtSavedSpot()
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.placeAtSavedSpot()
        })

        placeAtSavedSpot()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        displayLink?.invalidate()
    }

    override func close() {
        displayLink?.invalidate()
        displayLink = nil
        super.close()
    }

    /// The hosting view, set up so the window's size is ours to decide: by default it
    /// would hold the window to the SwiftUI content's ideal size and fight every resize.
    func host<Content: View>(_ root: Content) {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        contentView = hosting
    }

    // MARK: Placing

    private func placeAtSavedSpot() {
        let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
        guard let placed = OverlayPlacement.placement(saved: saved, geometry,
                                                      screens: NSScreen.screens.map(\.visibleFrame),
                                                      main: NSScreen.main?.visibleFrame) else { return }
        apply(placed)
    }

    private func apply(_ placed: OverlayPlacement.Placement) {
        placement = placed
        if layout.growsDown != (placed.growth == .down) { layout.growsDown = placed.growth == .down }
        layoutFrame()
    }

    /// The window around the strip, with the transcript at its current height.
    private func layoutFrame() {
        let frame = OverlayPlacement.frame(strip: placement.strip, geometry, growth: placement.growth,
                                           transcriptHeight: layout.transcriptHeight)
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
        // The shadow is recomputed once the growth settles, not on every frame of it:
        // rebuilding it 60 times a second is what makes a resizing window stutter.
        if displayLink == nil { invalidateShadow() }
    }

    // MARK: Growing the transcript

    /// How tall the transcript would like to be — its text and padding, 0 before the first
    /// word. Capped at the geometry's maximum, beyond which the text scrolls instead.
    func setTranscriptHeight(_ wanted: CGFloat) {
        let target = min(max(wanted, 0), geometry.maxTranscriptHeight)
        guard target != targetTranscriptHeight else { return }
        targetTranscriptHeight = target
        guard displayLink == nil, let view = contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = nil
    }

    /// One frame of the growth: an exponential ease towards the target — quick at first,
    /// settling softly — so a line landing mid-growth just moves the destination instead
    /// of restarting an animation.
    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(lastTick.map { now - $0 } ?? 1.0 / 60, 0.05)
        lastTick = now

        let current = layout.transcriptHeight
        let remaining = targetTranscriptHeight - current
        let next: CGFloat
        if abs(remaining) < 0.5 {
            next = targetTranscriptHeight
            link.invalidate()
            displayLink = nil  // `layoutFrame` below then settles the shadow
        } else {
            next = current + remaining * CGFloat(1 - exp(-dt / Self.growthTimeConstant))
        }
        layout.transcriptHeight = next
        layoutFrame()
    }

    /// Seconds for the transcript to cover ~63% of the way to its target height.
    private static let growthTimeConstant: CFTimeInterval = 0.09

    // MARK: Dragging

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressStart = (NSEvent.mouseLocation, placement.strip)
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let start = pressStart else { return super.sendEvent(event) }
            let mouse = NSEvent.mouseLocation
            let delta = CGPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
            if !isDragging {
                // A few points of slack, so a click on ✕ with a trembling hand is a click.
                guard hypot(delta.x, delta.y) >= 3 else { return super.sendEvent(event) }
                isDragging = true
            }
            let proposed = CGPoint(x: start.strip.x + delta.x, y: start.strip.y + delta.y)
            // The screen under the pointer, so the overlay can be carried to another display.
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? self.screen ?? NSScreen.main
            guard let screen else { return }
            apply(OverlayPlacement.settled(strip: proposed, geometry, in: screen.visibleFrame))

        case .leftMouseUp:
            defer { pressStart = nil; isDragging = false }
            guard isDragging else { return super.sendEvent(event) }
            UserDefaults.standard.set(OverlayPlacement.encode(placement.strip), forKey: SettingsKeys.overlayOrigin)
            // A button that took the mouse-down is released away from itself, so it lets go
            // without firing — the window moved with the pointer, which is still over it.
            // The bottom-left corner: inside the window, where no skin puts a button.
            if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 1, y: 1),
                                                modifierFlags: [], timestamp: event.timestamp,
                                                windowNumber: windowNumber, context: nil,
                                                eventNumber: event.eventNumber, clickCount: 1, pressure: 0) {
                super.sendEvent(release)
            }

        default:
            super.sendEvent(event)
        }
    }
}
