import SwiftUI
import AppKit

// MARK: - Inline overlay

/// The strip that floats above the dock while an inline dictation is running: a
/// language dial and a small LCD showing what the microphone is hearing.
///
/// It has no controls of its own by design — the hotkey starts and stops it. The only
/// affordance is a cancel button, revealed on hover so it doesn't clutter the glass.
struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let isPreparing: Bool
    /// Recolours the phosphor so an LLM-processed dictation is obvious at a glance.
    var isAIMode: Bool = false
    let onCancel: () -> Void

    /// The LCD next to the badge.
    static let screenSize = CGSize(width: 100, height: 56)
    static let spacing: CGFloat = 10
    static var panelSize: CGSize {
        CGSize(width: LanguageBadge.diameter + spacing + screenSize.width,
               height: screenSize.height)
    }

    /// 8 rows at the design's 7pt pitch, and enough columns to overrun the glass at
    /// both ends — the design clips the dot mask rather than framing it.
    private static let columns = 16
    private static let rows = 8
    private static let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)

    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @State private var langLabel: String = ""
    @State private var keyboardObserverID: UUID?
    @State private var isHovering = false
    @State private var isHoveringCancel = false

    private var mode: PixelDisplayMode {
        if isLoading || isPreparing { return .busy }
        return .level
    }

    private var palette: PixelPalette { isAIMode ? .ai : .phosphor }

    var body: some View {
        HStack(spacing: Self.spacing) {
            LanguageBadge(label: langLabel, isAIMode: isAIMode)
            screen
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            refreshLangLabel()
            keyboardObserverID = KeyboardChangeObserver.shared.addHandler { refreshLangLabel() }
        }
        .onDisappear {
            if let id = keyboardObserverID { KeyboardChangeObserver.shared.removeHandler(id: id) }
        }
        .onChange(of: selectedLanguage) { refreshLangLabel() }
    }

    private var screen: some View {
        ZStack {
            Self.glass.fill(Skin.screen)

            PixelWaveform(
                levels: barLevels,
                columns: Self.columns,
                rows: Self.rows,
                mode: mode,
                palette: palette
            )

            // The design's inset shadow — it seats the glass into the panel edge.
            InnerShadow(shape: Self.glass, width: 6.6, blur: 3.3)
            InnerShadow(shape: Self.glass, width: 4, blur: 2,
                        offset: CGSize(width: 0, height: -1))

            if isHovering {
                cancelButton
                    .transition(.opacity)
            }
        }
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
        .clipShape(Self.glass)
        .contentShape(Self.glass)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(isHoveringCancel ? 1 : 0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(isHoveringCancel ? 0.75 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Cancel (nothing is pasted)")
        .onHover { hovering in
            isHoveringCancel = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringCancel)
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

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Skin.phosphorText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Skin.phosphorText.opacity(0.6))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Skin.screen)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Skin.phosphor.opacity(isHovering ? 0.35 : 0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
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
    init() {
        let size = RecordingOverlayView.panelSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
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
        let x = screenFrame.midX - RecordingOverlayView.panelSize.width / 2
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
