import SwiftUI

// MARK: - Palette

/// The three inks the dot matrix can print with.
struct PixelPalette {
    let off: Color
    let on: Color
    let peak: Color

    static let phosphor = PixelPalette(off: Skin.pixelOff, on: Skin.phosphor, peak: Skin.peak)
    /// AI mode: same display, different phosphor.
    static let ai = PixelPalette(off: Skin.pixelOff, on: Skin.aiPhosphor, peak: Skin.peak)
}

// MARK: - Modes

/// What the matrix is showing. The engine has more states than this, but every one of
/// them maps onto "nothing happening", "listening" or "waiting on something".
enum PixelDisplayMode: Equatable {
    /// Idle — the dot mask sits unlit against the glass.
    case idle
    /// Live audio: a bar chart of the last couple of seconds, scrolling right to left.
    case level
    /// Working (starting the engine, transcribing, rewriting): a comet sweeps the
    /// bottom rows so the user can tell the app hasn't simply stopped.
    case busy
}

// MARK: - Matrix

/// The LCD dot matrix.
///
/// Columns light from the bottom up. A loud column burns white with a single lit dot
/// left green at its cap, which is what gives the design's equaliser its texture.
struct PixelMatrix: View {
    /// One level per column, 0…1, oldest first.
    let levels: [CGFloat]
    let rows: Int
    let mode: PixelDisplayMode
    var palette: PixelPalette = .phosphor
    /// Sweep position for `.busy`, in columns.
    var sweep: Double = 0

    var cell: CGFloat = Skin.pixel
    var pitch: CGFloat = Skin.pixelPitch

    /// Total size a matrix of this shape occupies.
    static func size(columns: Int, rows: Int,
                     cell: CGFloat = Skin.pixel, pitch: CGFloat = Skin.pixelPitch) -> CGSize {
        CGSize(width: CGFloat(max(columns, 0)) * pitch - (pitch - cell),
               height: CGFloat(max(rows, 0)) * pitch - (pitch - cell))
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for column in 0..<levels.count {
                for row in 0..<rows {
                    let rect = CGRect(
                        x: CGFloat(column) * pitch,
                        y: CGFloat(rows - 1 - row) * pitch,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(ink(column: column, row: row)))
                }
            }
        }
        .frame(
            width: Self.size(columns: levels.count, rows: rows, cell: cell, pitch: pitch).width,
            height: Self.size(columns: levels.count, rows: rows, cell: cell, pitch: pitch).height
        )
    }

    /// `row` counts from the bottom.
    private func ink(column: Int, row: Int) -> Color {
        switch mode {
        case .idle:
            return palette.off

        case .level:
            let level = levels[column]
            let lit = Int((level * CGFloat(rows)).rounded())
            guard row < lit else { return palette.off }
            // Leave the topmost dot green so a tall column reads as a capped bar
            // rather than a solid white block.
            return level >= 0.5 && row < lit - 1 ? palette.peak : palette.on

        case .busy:
            guard row < 2 else { return palette.off }
            let distance = abs(Double(column) - sweep)
            switch distance {
            case ..<1: return palette.peak
            case ..<2.5: return palette.on
            case ..<4.5: return palette.on.opacity(0.45)
            default: return palette.off
            }
        }
    }
}

// MARK: - Driver

/// Feeds the matrix.
///
/// The audio tap fires at whatever rate Core Audio feels like, so the display is
/// driven off its own 30Hz clock instead: each tick pushes the current level into a
/// rolling history. That keeps the scroll speed steady whether the engine is handing
/// us 10 or 45 buffers a second.
struct PixelWaveform: View {
    /// `SpeechEngine.barLevels` — a fresh set of per-segment RMS values on each tap.
    let levels: [CGFloat]
    let columns: Int
    let rows: Int
    let mode: PixelDisplayMode
    var palette: PixelPalette = .phosphor
    var cell: CGFloat = Skin.pixel
    var pitch: CGFloat = Skin.pixelPitch

    /// Columns scrolled per second.
    private static let refreshRate = 30.0

    @State private var history: [CGFloat] = []
    /// Sawtooth over `[0, 2·span)`; folded into a triangle for the visible position so
    /// the comet turns around at the ends instead of jumping back.
    @State private var sweepPhase: Double = 0
    @State private var feed = LevelFeed()

    private var span: Double { Double(max(columns - 1, 1)) }
    private var sweep: Double { sweepPhase > span ? 2 * span - sweepPhase : sweepPhase }

    var body: some View {
        PixelMatrix(
            levels: history.isEmpty ? Array(repeating: 0, count: columns) : history,
            rows: rows,
            mode: mode,
            palette: palette,
            sweep: sweep,
            cell: cell,
            pitch: pitch
        )
        .onChange(of: levels, initial: true) { feed.levels = levels }
        .task(id: mode) {
            if mode != .level { history = Array(repeating: 0, count: columns) }
            guard mode != .idle else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(1000 / Self.refreshRate)))
                guard !Task.isCancelled else { return }
                advance()
            }
        }
    }

    private func advance() {
        switch mode {
        case .level:
            guard columns > 0 else { return }
            var next = history.count == columns ? history : Array(repeating: 0, count: columns)
            next.removeFirst()
            next.append(currentLevel)
            history = next
        case .busy:
            sweepPhase += 0.55
            if sweepPhase > span * 2 { sweepPhase -= span * 2 }
        case .idle:
            break
        }
    }

    /// One column's worth of loudness.
    ///
    /// The engine hands over per-segment RMS for the whole buffer; the mean is what
    /// that instant actually sounded like. Taking the peak instead pins nearly every
    /// column to full height, because a single transient in any segment wins.
    private var currentLevel: CGFloat {
        let levels = feed.levels
        guard !levels.isEmpty else { return 0 }
        return levels.reduce(0, +) / CGFloat(levels.count)
    }

    /// A box the animation task can read through: `.task` captures the view struct by
    /// value, so a plain stored property would freeze at whatever it held when the
    /// task started.
    private final class LevelFeed {
        var levels: [CGFloat] = []
    }
}
