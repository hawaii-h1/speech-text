import SwiftUI
import AppKit

// MARK: - Overlay View

struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barLevels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: barHeight(barLevels[i]))
                    .animation(.interpolatingSpring(stiffness: 300, damping: 18), value: barLevels[i])
            }
        }
        .frame(width: 105, height: 65)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 32))
    }

    private func barHeight(_ level: CGFloat) -> CGFloat {
        let minH: CGFloat = 6
        let maxH: CGFloat = 42
        return minH + level * (maxH - minH)
    }
}

// MARK: - Panel

final class RecordingOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 105, height: 65),
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
        let x = screenFrame.midX - 105 / 2
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
