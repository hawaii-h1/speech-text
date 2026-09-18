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
    /// Draw the transcript above the strip. Fixed for the life of the panel, which is
    /// sized for it — see `AppSkin.overlaySize(showsTranscript:)`.
    var showsTranscript: Bool = false
    /// What the provider has committed, all segments — drawn at full brightness.
    var settledText: String = ""
    /// The partial it may still take back — drawn dimmer, after the settled text.
    var movingText: String = ""
    let onCancel: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral

    @State private var isHoveringCancel = false

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }
    private var accent: Color { isAIMode ? Semantic.ai : AccentColor.meter(accentHex) }
    private var isBusy: Bool { isLoading || isPreparing }

    var body: some View {
        let size = skin.overlaySize(showsTranscript: showsTranscript)
        Group {
            switch skin {
            case .minimal: minimalBody
            case .techno: technoBody
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Transcript

    /// The settled text, then the partial, at two brightnesses — the same boundary the
    /// Record Window's glass draws. Before the first word, what the recording is doing.
    private func transcriptText(base: Color) -> Text {
        guard !settledText.isEmpty || !movingText.isEmpty else {
            let placeholder = isPreparing ? "Starting…" : isLoading ? "Transcribing…" : "Listening…"
            return Text(placeholder).foregroundStyle(base.opacity(0.45))
        }
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

    /// The transcript, kept scrolled to its newest line: the words the user is saying
    /// now are the ones they are checking.
    private func transcript(base: Color, font: Font) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    transcriptText(base: base)
                        .font(font)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id(Self.transcriptEnd)
                }
            }
            .onChange(of: settledText) { proxy.scrollTo(Self.transcriptEnd, anchor: .bottom) }
            .onChange(of: movingText) { proxy.scrollTo(Self.transcriptEnd, anchor: .bottom) }
            .onAppear { proxy.scrollTo(Self.transcriptEnd, anchor: .bottom) }
        }
    }

    private static let transcriptEnd = "transcriptEnd"

    // MARK: Minimal

    /// One piece of glass: the strip is a capsule, and with a transcript the glass keeps
    /// the capsule's radius so the strip's ends are the panel's bottom corners.
    private var minimalShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin.overlayStripSize.height / 2, style: .continuous)
    }

    private var minimalBody: some View {
        VStack(spacing: 0) {
            if showsTranscript {
                transcript(base: .primary, font: .system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            minimalStrip
                .background {
                    if showsTranscript { Capsule().fill(.primary.opacity(0.07)) }
                }
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
    }

    // MARK: Techno

    /// 8 rows at the design's 7pt pitch, and enough columns to overrun the glass at
    /// both ends — the design clips the dot mask rather than framing it.
    private static let technoColumns = 16
    private static let technoRows = 8
    private static let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private static let transcriptGlass = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var technoBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if showsTranscript { technoTranscript }
            technoStrip
        }
    }

    /// The transcript on a glass of its own, phosphor on black like the Record Window's.
    private var technoTranscript: some View {
        ZStack {
            Self.transcriptGlass.fill(TechnoSkin.screen)
            transcript(base: isAIMode ? TechnoSkin.aiText : TechnoSkin.phosphorText,
                       font: .system(size: 12, design: .monospaced))
                // Lines scrolling past the glass's rim fade instead of being sliced.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.15),
                                             .init(color: .black, location: 0.85),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            InnerShadow(shape: Self.transcriptGlass, width: 6.6, blur: 3.3)
            InnerShadow(shape: Self.transcriptGlass, width: 4, blur: 2,
                        offset: CGSize(width: 0, height: -1))
        }
        .frame(height: skin.overlayTranscriptHeight)
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
        let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
        guard let origin = OverlayPlacement.origin(saved: saved, size: frame.size,
                                                   screens: NSScreen.screens.map(\.visibleFrame),
                                                   main: NSScreen.main?.visibleFrame) else { return }
        setFrameOrigin(origin)
    }
}

// MARK: - Panel

/// The inline overlay's window. It opens where the user last dragged it — the bottom-right
/// corner until they do — and never outside a screen: the saved spot is checked against
/// the screens there are *now* every time the panel is shown, resized or the displays
/// change, so an unplugged monitor or a lower resolution cannot leave it out of sight.
final class RecordingOverlayPanel: NSPanel {
    private let showsTranscript: Bool
    private var observers: [NSObjectProtocol] = []
    /// Where the panel last put itself. Move notifications arrive after `setFrame` has
    /// returned, so a flag set around the call cannot tell them apart; a move that ends
    /// here is the panel's own, and only the user's drags are remembered — otherwise the
    /// fallback for an unplugged monitor would overwrite the spot the user chose on it.
    private var placedOrigin: CGPoint?

    init(showsTranscript: Bool = false) {
        self.showsTranscript = showsTranscript
        super.init(
            contentRect: NSRect(origin: .zero, size: AppSkin.current.overlaySize(showsTranscript: showsTranscript)),
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

        let center = NotificationCenter.default
        // The hosted view reflows itself, but the window it sits in does not.
        observers.append(center.addObserver(forName: .skinDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.place(size: AppSkin.current.overlaySize(showsTranscript: self.showsTranscript))
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.place(size: nil)
        })
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: self,
                                            queue: .main) { [weak self] _ in
            self?.rememberPosition()
        })

        place(size: nil)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Puts the panel at its remembered spot, resized to `size` first when given. The
    /// bottom-left corner is what is kept, so a taller panel grows upward.
    private func place(size: CGSize?) {
        let size = size ?? frame.size
        let screens = NSScreen.screens.map(\.visibleFrame)
        let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
        guard let origin = OverlayPlacement.origin(saved: saved, size: size, screens: screens,
                                                   main: NSScreen.main?.visibleFrame) else { return }
        placedOrigin = origin
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Called for every move; only a drag by the user is saved, and saved as it ended up
    /// on screen — a drag past the edge is pulled back in rather than remembered off it.
    private func rememberPosition() {
        guard frame.origin != placedOrigin else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let origin = OverlayPlacement.origin(saved: frame.origin, size: frame.size, screens: screens,
                                             main: NSScreen.main?.visibleFrame) ?? frame.origin
        UserDefaults.standard.set(OverlayPlacement.encode(origin), forKey: SettingsKeys.overlayOrigin)
    }
}
