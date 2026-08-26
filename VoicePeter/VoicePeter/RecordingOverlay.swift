import SwiftUI
import AppKit

// MARK: - Reusable Waveform Bars

struct WaveformBarsView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    var isPreparing: Bool = false
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var minBarHeight: CGFloat = 6
    var maxBarHeight: CGFloat = 42
    var barColor: Color = .white

    @State private var activeDot: Int = 0
    /// How many bars have been revealed during the preparing phase.
    @State private var revealedCount: Int = 0
    /// Flips to true when the engine is ready and bars snap to full brightness.
    @State private var barsBright: Bool = false

    /// True while bars are in the dim one-by-one reveal or the snap-to-bright transition.
    private var inPreparingDisplay: Bool {
        isPreparing || (revealedCount > 0 && !barsBright)
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barLevels.count, id: \.self) { i in
                let dimmed = inPreparingDisplay
                let visible = !dimmed || i < revealedCount

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(barOpacity(index: i, visible: visible, dimmed: dimmed)))
                    .frame(width: barWidth, height: dimmed ? minBarHeight : barFrameHeight(barLevels[i]))
                    .animation(.easeInOut(duration: 0.35), value: isLoading)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: revealedCount)
                    .animation(.easeOut(duration: 0.25), value: barsBright)
                    .animation(.interpolatingSpring(stiffness: 300, damping: 18), value: barLevels[i])
            }
        }
        // Preparing animation: reveal bars one by one (dim), then brighten when engine is ready
        .task(id: isPreparing) {
            if isPreparing {
                revealedCount = 0
                barsBright = false
                for _ in 0..<barLevels.count {
                    try? await Task.sleep(for: .milliseconds(85))
                    if Task.isCancelled { break }
                    withAnimation {
                        revealedCount += 1
                    }
                }
            } else if revealedCount > 0 {
                // Snap any remaining bars in (still dim), then brighten all at once
                withAnimation(.easeOut(duration: 0.06)) {
                    revealedCount = barLevels.count
                }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    barsBright = true
                }
                // Wait for brighten animation to finish, then reset state so normal
                // waveform takes over cleanly (inPreparingDisplay becomes false).
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                revealedCount = 0
                barsBright = false
            }
        }
        // Transcribing animation: dot-chase across the bars
        .task(id: isLoading) {
            guard isLoading else { return }
            activeDot = 0
            let count = barLevels.count
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.15)) {
                    activeDot = (activeDot + 1) % count
                }
            }
        }
    }

    private func barOpacity(index: Int, visible: Bool, dimmed: Bool) -> Double {
        if isLoading { return loadingOpacity(for: index) }
        if dimmed { return visible ? 0.38 : 0.0 }
        return 0.85
    }

    private func barFrameHeight(_ level: CGFloat) -> CGFloat {
        isLoading ? minBarHeight : (minBarHeight + level * (maxBarHeight - minBarHeight))
    }

    private func loadingOpacity(for index: Int) -> Double {
        let count = barLevels.count
        guard count > 0 else { return 0.15 }
        let distance = min(
            abs(index - activeDot),
            count - abs(index - activeDot)
        )
        switch distance {
        case 0: return 1.0
        case 1: return 0.6
        case 2: return 0.35
        default: return 0.15
        }
    }
}

// MARK: - Overlay View

struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let isPreparing: Bool
    /// Tints the overlay so the user can tell an LLM-processed recording apart
    /// from a plain one at a glance.
    var isAIMode: Bool = false
    let onCancel: () -> Void

    private var accent: Color { isAIMode ? Color(red: 0.72, green: 0.55, blue: 1.0) : .white }

    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @State private var langLabel: String = ""
    @State private var keyboardObserverID: UUID?
    @State private var isHoveringCancel = false

    private func refreshLangLabel() {
        let locale = resolvedLocale()
        langLabel = locale.components(separatedBy: "-").first.map { $0.uppercased() } ?? "?"
    }

    var body: some View {
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
                    .foregroundStyle(.white.opacity(isHoveringCancel ? 1.0 : 0.6))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(isHoveringCancel ? 0.18 : 0))
                    )
                    .scaleEffect(isHoveringCancel ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringCancel = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .animation(.easeInOut(duration: 0.15), value: isHoveringCancel)
        }
        .padding(.horizontal, 10)
        .frame(height: 65)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay {
            if isAIMode {
                RoundedRectangle(cornerRadius: 32)
                    .stroke(accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .onAppear {
            refreshLangLabel()
            keyboardObserverID = KeyboardChangeObserver.shared.addHandler { refreshLangLabel() }
        }
        .onDisappear {
            if let id = keyboardObserverID { KeyboardChangeObserver.shared.removeHandler(id: id) }
        }
        .onChange(of: selectedLanguage) { refreshLangLabel() }
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
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(isHovering ? 0.25 : 0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 197, height: 65),
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
        let x = screenFrame.midX - 197 / 2
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
