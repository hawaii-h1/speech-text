// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Palette

/// The three inks the dot matrix can print with.
struct PixelPalette {
    let off: Color
    let on: Color
    let peak: Color

    /// The display in the user's colour.
    static func phosphor(_ techno: TechnoPalette) -> PixelPalette {
        PixelPalette(off: TechnoSkin.pixelOff, on: techno.phosphor, peak: techno.peak)
    }
    /// AI mode: same display, different phosphor.
    static let ai = PixelPalette(off: TechnoSkin.pixelOff, on: TechnoSkin.aiPhosphor, peak: TechnoSkin.aiPeak)
}

// MARK: - Noise

/// Deterministic jitter in `0…1`.
///
/// Hashed from its inputs rather than drawn from a random source: SwiftUI re-evaluates
/// a body whenever it likes, and a random draw would reshuffle the whole display under
/// the animation. Same inputs, same grid.
enum PixelNoise {
    static func value(_ a: Int, _ b: Int, _ c: Int = 0) -> CGFloat {
        var h = UInt64(bitPattern: Int64(a &* 0x2545_F491 &+ b &* 0x1F12_3BB5 &+ c &* 0x27D4_EB2D))
        h ^= h >> 33
        h = h &* 0xff51_afd7_ed55_8ccd
        h ^= h >> 29
        return CGFloat(h % 4_096) / 4_095
    }
}

// MARK: - Modes

/// What the matrix is showing. The engine has more states than this, but every one of
/// them maps onto "nothing happening", "listening" or "waiting on something".
enum PixelDisplayMode: Equatable {
    /// Idle — the dot mask sits unlit against the glass.
    case idle
    /// Live audio: every column bounces in place with the current loudness.
    case level
    /// Working (starting the engine, transcribing, rewriting): a comet sweeps the
    /// bottom rows so the user can tell the app hasn't simply stopped.
    case busy
}

// MARK: - Matrix

/// The LCD dot matrix.
///
/// Columns light from the bottom up, and a column burns white from the bottom in
/// proportion to how loud it is, leaving its cap green — that white core is what gives
/// the design's equaliser its texture. Every lit dot also carries a little hashed
/// variation in brightness, so the field looks like phosphor rather than like a chart.
struct PixelMatrix: View {
    /// One level per column, 0…1, oldest first.
    let levels: [CGFloat]
    let rows: Int
    let mode: PixelDisplayMode
    let palette: PixelPalette
    /// Sweep position for `.busy`, in columns.
    var sweep: Double = 0
    /// Advances the per-dot texture. Constant within a draw, so a redraw of the same
    /// frame produces the same dots.
    var seed: Int = 0

    var cell: CGFloat = TechnoSkin.pixel
    var pitch: CGFloat = TechnoSkin.pixelPitch

    /// Total size a matrix of this shape occupies.
    static func size(columns: Int, rows: Int,
                     cell: CGFloat = TechnoSkin.pixel, pitch: CGFloat = TechnoSkin.pixelPitch) -> CGSize {
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

    /// The fraction of a column that burns white, ramped in from a murmur to a shout.
    private func whiteShare(_ level: CGFloat) -> CGFloat {
        min(0.6, max(0, (level - 0.2) / 0.75))
    }

    /// `row` counts from the bottom.
    private func ink(column: Int, row: Int) -> Color {
        switch mode {
        case .idle:
            return palette.off

        case .level:
            // Never shorter than the bottom row: between two words the level falls to
            // nothing, and a display that blanks out reads as "it stopped listening".
            let height = max(levels[column] * CGFloat(rows), 1)
            let full = Int(height)
            guard row <= full else { return palette.off }

            // The cap fades in as the column grows into it, instead of a whole dot
            // appearing at once. Eight rows is coarse, and this is what makes the
            // movement between two of them look continuous.
            let cap = height - CGFloat(full)
            guard row < full || cap > 0.06 else { return palette.off }
            let capFade: CGFloat = row == full ? 0.3 + 0.7 * cap : 1

            // How deep the white core runs. A quiet column keeps a dot or two of it at
            // the bottom, a loud one is white nearly to its cap.
            let core = Int((CGFloat(full) * whiteShare(levels[column])).rounded())
            let ink = row < core ? palette.peak : palette.on

            // Per-dot brightness, so neighbouring dots are never quite the same shade.
            let texture = 0.8 + 0.2 * PixelNoise.value(column, row, seed)
            return ink.opacity(capFade * texture)

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
/// driven off its own 30Hz clock instead. Every column is redrawn from the *current*
/// loudness on each tick: the grid jumps up and down in place, the way a hardware
/// equaliser does. It deliberately does not scroll a history sideways — a track
/// travelling across the glass reads as a progress bar, not as a voice.
struct PixelWaveform: View {
    /// `SpeechEngine.barLevels` — a fresh set of per-segment RMS values on each tap.
    let levels: [CGFloat]
    let columns: Int
    let rows: Int
    let mode: PixelDisplayMode
    let palette: PixelPalette
    var cell: CGFloat = TechnoSkin.pixel
    var pitch: CGFloat = TechnoSkin.pixelPitch

    /// Ticks per second.
    private static let refreshRate = 30.0
    /// How many ticks a column holds the same noise draw. Redrawing the noise at the
    /// full 30Hz strobes; a fifth of that reads as movement, and the eased attack
    /// below carries the column smoothly between two draws.
    private static let noiseHold = 5
    /// A normal speaking voice sits low in the RMS range and only a shout approaches
    /// the top of it, so the level goes through a compressive curve rather than a
    /// plain multiplier: `gain` lifts conversation off the floor, and `curve` (< 1)
    /// keeps the loud end from saturating once it is up there.
    private static let gain: CGFloat = 2.8
    private static let curve: Double = 0.7
    /// Below this the room is just quiet. Without a floor the display twitches at
    /// nothing, since even silence carries some RMS.
    private static let noiseFloor: CGFloat = 0.02
    /// How far a column travels towards its target on each tick. Rising is quicker
    /// than falling — the attack is what makes a syllable visible, the slower release
    /// is what stops the grid flickering off between them — but neither is a jump:
    /// stepping straight onto the target made the columns twitch between draws.
    private static let attack: CGFloat = 0.45
    private static let release: CGFloat = 0.16

    /// One height per column, 0…1 — where the columns are *now*, not where they were.
    @State private var columnLevels: [CGFloat] = []
    @State private var tick = 0
    /// Sawtooth over `[0, 2·span)`; folded into a triangle for the visible position so
    /// the comet turns around at the ends instead of jumping back.
    @State private var sweepPhase: Double = 0
    @State private var feed = LevelFeed()

    private var span: Double { Double(max(columns - 1, 1)) }
    private var sweep: Double { sweepPhase > span ? 2 * span - sweepPhase : sweepPhase }

    var body: some View {
        PixelMatrix(
            levels: columnLevels.count == columns ? columnLevels : Array(repeating: 0, count: columns),
            rows: rows,
            mode: mode,
            palette: palette,
            sweep: sweep,
            seed: tick / Self.noiseHold,
            cell: cell,
            pitch: pitch
        )
        .onChange(of: levels, initial: true) { feed.levels = levels }
        .task(id: mode) {
            columnLevels = Array(repeating: 0, count: columns)
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
            let level = displayLevel
            let draw = tick / Self.noiseHold
            tick += 1
            var next = columnLevels.count == columns ? columnLevels : Array(repeating: 0, count: columns)
            for column in 0..<columns {
                let target = min(1, level * profile(column) * noise(column: column, draw: draw))
                let rate = target > next[column] ? Self.attack : Self.release
                next[column] += (target - next[column]) * rate
            }
            columnLevels = next
        case .busy:
            sweepPhase += 0.55
            if sweepPhase > span * 2 { sweepPhase -= span * 2 }
        case .idle:
            break
        }
    }

    /// A bell across the display: the middle columns are boosted and the ends held
    /// back, so the noise gathers into a wave instead of standing as a rectangle with
    /// a ragged top edge. The centre is allowed above 1 — it clamps against the top of
    /// the glass first, which is what makes the crest read as a crest.
    private func profile(_ column: Int) -> CGFloat {
        guard columns > 1 else { return 1 }
        let t = Double(column) / Double(columns - 1)
        return CGFloat(0.66 + 0.52 * pow(sin(.pi * t), 1.2))
    }

    /// Per-column jitter, in `0.5…1.35`. Wide on purpose: the columns are all fed the
    /// same loudness, and it is this spread that makes them read as a voice rather
    /// than as one bar drawn many times.
    private func noise(column: Int, draw: Int) -> CGFloat {
        0.5 + 0.85 * PixelNoise.value(column, draw)
    }

    /// The height the columns are aiming for, 0…1.
    private var displayLevel: CGFloat {
        let mean = currentLevel
        guard mean > Self.noiseFloor else { return 0 }
        let lifted = min(1, (mean - Self.noiseFloor) * Self.gain)
        return CGFloat(pow(Double(lifted), Self.curve))
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
