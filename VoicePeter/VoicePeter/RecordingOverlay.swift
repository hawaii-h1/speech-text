import SwiftUI
import AppKit

// MARK: - Overlay View

struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let onCancel: () -> Void

    @State private var activeDot: Int = 0

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barLevels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(isLoading ? loadingOpacity(for: i) : 0.85))
                    .frame(width: 4, height: isLoading ? 6 : barHeight(barLevels[i]))
                    .animation(.easeInOut(duration: 0.35), value: isLoading)
                    .animation(.interpolatingSpring(stiffness: 300, damping: 18), value: barLevels[i])
            }
        }
        .frame(width: 105, height: 65)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 32))
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
