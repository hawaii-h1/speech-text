// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns a microphone's raw loudness into the height the level meter draws — an
/// automatic gain for the display alone; the audio sent to an engine is never touched.
///
/// A fixed gain was tuned against one microphone: a headset's sits a few centimetres
/// from the mouth, a MacBook's half a metre away, and the same voice came out tens of
/// decibels apart — on the Mac's own microphone the meter barely moved. The meter is
/// there to show that the app hears the user, not to measure them, so it follows the
/// voice *relative to itself*: louder rises, quieter falls, and any microphone fills
/// the display.
///
/// Works in decibels, the scale loudness is heard on. Two followers set the window:
/// the room's `floor` (quick to fall into a pause, slow to rise, so speech does not
/// drag it up) and the voice's `peak` (onto a louder sound at once, back down over a
/// few seconds). A level is placed between `floor + gate` and `peak`. The window is
/// never narrower than `minimumRange`, so a silent room is not stretched until its
/// hiss fills the glass.
///
/// One per tap: a new device starts from the defaults rather than from the scale of
/// the one before it. Pure logic, in SpeechTextCore.
public struct LevelNormalizer: Sendable {
    /// Where the room is assumed to start: a quiet room on a built-in microphone.
    static let initialFloor: Double = -60
    /// Where the voice is assumed to start — low enough that a quiet voice on a distant
    /// microphone shows at once, and a louder one lifts it on its first syllable.
    static let initialPeak: Double = -30
    /// The narrowest window between the floor and the peak, in dB. Below it, noise would
    /// be scaled up into something that looks like a voice.
    static let minimumRange: Double = 24
    /// How far above the floor a sound must be to light anything: the room's own
    /// flutter stays dark.
    static let gate: Double = 6
    /// Time constants, in seconds.
    static let floorFall: Double = 0.25
    static let floorRise: Double = 3
    static let peakFall: Double = 2.5
    /// Nothing is quieter than this; digital silence would otherwise drag the floor to
    /// −∞ and the window with it.
    static let lowestLevel: Double = -100

    private(set) var floor = initialFloor
    private(set) var peak = initialPeak

    public init() {}

    /// The display heights, 0…1, for one buffer's per-segment RMS values (linear,
    /// 0…1 full scale), lasting `seconds` together.
    public mutating func levels(rms: [Float], seconds: Double) -> [CGFloat] {
        guard !rms.isEmpty else { return [] }
        let power = rms.reduce(0) { $0 + Double($1) * Double($1) } / Double(rms.count)
        let loudness = Self.decibels(power.squareRoot())

        let floorTau = loudness < floor ? Self.floorFall : Self.floorRise
        floor += (loudness - floor) * Self.step(seconds, tau: floorTau)
        if loudness > peak {
            peak = loudness
        } else {
            peak += (loudness - peak) * Self.step(seconds, tau: Self.peakFall)
        }
        peak = max(peak, floor + Self.minimumRange)

        let bottom = floor + Self.gate
        let span = peak - bottom
        return rms.map { segment in
            CGFloat(min(1, max(0, (Self.decibels(Double(segment)) - bottom) / span)))
        }
    }

    private static func decibels(_ rms: Double) -> Double {
        rms > 0 ? max(lowestLevel, 20 * log10(rms)) : lowestLevel
    }

    /// The fraction of the way to its target a follower moves in `seconds`.
    private static func step(_ seconds: Double, tau: Double) -> Double {
        1 - exp(-max(0, seconds) / tau)
    }
}
