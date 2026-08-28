import SwiftUI
import AppKit

// MARK: - Inline overlay

/// The strip that floats above the dock while an inline dictation is running.
///
/// It has no controls of its own by design — the hotkey starts and stops it. The only
/// affordance is a cancel button, kept beside the display rather than over it.
///
/// Both skins live here rather than in separate files: they show the same three states
/// (listening, working, AI) from the same inputs, and keeping them in one place is what
/// stops one of them from quietly falling behind.
struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let isPreparing: Bool
    /// Recolours the display so an LLM-processed dictation is obvious at a glance.
    var isAIMode: Bool = false
    let onCancel: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID

    @State private var langLabel: String = ""
    @State private var keyboardObserverID: UUID?
    @State private var isHoveringCancel = false

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }
    private var accent: Color { isAIMode ? Semantic.ai : AccentColor.meter(accentHex) }
    private var isBusy: Bool { isLoading || isPreparing }

    var body: some View {
        Group {
            switch skin {
            case .minimal: minimalBody
            case .techno: technoBody
            }
        }
        .frame(width: skin.overlaySize.width, height: skin.overlaySize.height)
        .onAppear {
            refreshLangLabel()
            keyboardObserverID = KeyboardChangeObserver.shared.addHandler { refreshLangLabel() }
        }
        .onDisappear {
            if let id = keyboardObserverID { KeyboardChangeObserver.shared.removeHandler(id: id) }
        }
        .onChange(of: selectedLanguage) { refreshLangLabel() }
    }

    // MARK: Minimal

    private var minimalBody: some View {
        HStack(spacing: 8) {
            Text(langLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent.opacity(0.9))
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accent.opacity(isAIMode ? 0.6 : 0.35), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isAIMode {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(accent)
                            .offset(x: 4, y: -3)
                    }
                }

            WaveformBarsView(
                barLevels: barLevels,
                isLoading: isLoading,
                isPreparing: isPreparing,
                barColor: accent
            )
            .frame(width: 105, height: 65)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(isHoveringCancel ? 1.0 : 0.6))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.primary.opacity(isHoveringCancel ? 0.12 : 0))
                    )
                    .scaleEffect(isHoveringCancel ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .help("Cancel (nothing is pasted)")
            .onHover { hovering in
                isHoveringCancel = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .animation(.easeInOut(duration: 0.15), value: isHoveringCancel)
        }
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay {
            // Only AI mode gets an outline; a plain dictation is meant to be a quiet
            // sliver of glass over whatever the user is working in.
            if isAIMode {
                RoundedRectangle(cornerRadius: 32).stroke(accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    // MARK: Techno

    /// 8 rows at the design's 7pt pitch, and enough columns to overrun the glass at
    /// both ends — the design clips the dot mask rather than framing it.
    private static let technoColumns = 16
    private static let technoRows = 8
    private static let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)

    private var technoBody: some View {
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
    }

    private func refreshLangLabel() {
        let locale = resolvedLocale()
        langLabel = locale.components(separatedBy: "-").first.map { $0.uppercased() } ?? "?"
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
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true

        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Panel

final class RecordingOverlayPanel: NSPanel {
    private var skinObserver: NSObjectProtocol?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: AppSkin.current.overlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true

        // The hosted view reflows itself, but the window it sits in does not.
        skinObserver = NotificationCenter.default.addObserver(
            forName: .skinDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setContentSize(AppSkin.current.overlaySize)
            self?.positionBottomCenter()
        }

        positionBottomCenter()
    }

    deinit {
        if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // Centred on the display, not on the panel — see `AppSkin.overlayFocusX`.
        setFrameOrigin(NSPoint(x: screenFrame.midX - AppSkin.current.overlayFocusX,
                               y: screenFrame.minY + 20))
    }
}
