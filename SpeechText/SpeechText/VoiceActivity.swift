// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Voice activity detection (#172): whether a segment's audio holds a human voice at all,
// asked before an upload and before a stream's answer is pasted. Keyboard typing and room
// noise are louder than `STTTuning.silencePeakFloor`, so they reached the engines, which
// answered «Thank you for watching.» or «so» — and that was pasted. A model that hears a
// voice in a window says so with a probability; this file decides what those mean, and
// the detector itself (Silero VAD, through FluidAudio) is registered at launch from
// `VoiceActivityRuntime.swift`, the way `LocalSTT` is — so this file stays in the test
// subset and the test bundle never sees FluidAudio.

/// Turns a segment's 16 kHz mono samples into one speech probability per window.
protocol VoiceActivityDetector: AnyObject, Sendable {
    func speechProbabilities(_ samples: [Float]) async throws -> [Float]
}

/// What the detector said about one segment.
struct VoiceActivityReading: Equatable {
    /// The highest probability of any window.
    var maxProbability: Float
    /// How many windows were above `STTTuning.voiceProbabilityThreshold`.
    var windowsOverThreshold: Int
    /// How long the segment was.
    var segmentSeconds: Double

    init(probabilities: [Float], segmentSeconds: Double) {
        maxProbability = probabilities.max() ?? 0
        windowsOverThreshold = probabilities.filter { $0 > STTTuning.voiceProbabilityThreshold }.count
        self.segmentSeconds = segmentSeconds
    }

    /// How many windows this segment needs: one for a short segment — a one-word
    /// dictation — and two for a longer one, where a single window is a spike of noise.
    var windowsRequired: Int {
        segmentSeconds <= STTTuning.voiceShortSegmentSeconds
            ? STTTuning.voiceWindowsRequiredWhenShort : STTTuning.voiceWindowsRequired
    }

    /// A voice was heard: at least `windowsRequired` windows over the threshold.
    var holdsSpeech: Bool { windowsOverThreshold >= windowsRequired }
}

enum VoiceActivity {
    /// Set at launch by `registerVoiceActivity`, once the model has loaded; nil — the test
    /// bundle, or a model that would not load — lets every segment through, as before.
    nonisolated(unsafe) static var detector: VoiceActivityDetector?

    /// The detector's reading of what `writer` holds; nil when there is nothing to judge
    /// with — no detector, audio that was never converted (the native fallback, which is
    /// unmeasured and counts as speech, as it does for the silence guard), or a detector
    /// that failed. nil never drops anything.
    static func read(_ writer: AudioBufferWriter) async -> VoiceActivityReading? {
        guard let detector, let samples = writer.convertedSamples, !samples.isEmpty else { return nil }
        let start = Date()
        do {
            let reading = VoiceActivityReading(probabilities: try await detector.speechProbabilities(samples),
                                               segmentSeconds: Double(samples.count) / AudioBufferWriter.uploadSampleRate)
            dlog("Engine", String(format: "voice activity: max %.2f, %d windows over %.2f (%d needed for %.1f s), %.0f ms",
                                  reading.maxProbability, reading.windowsOverThreshold,
                                  STTTuning.voiceProbabilityThreshold, reading.windowsRequired,
                                  reading.segmentSeconds, Date().timeIntervalSince(start) * 1000))
            return reading
        } catch {
            dlog("Engine", "voice activity: the detector failed — the segment is kept: \(error.localizedDescription)")
            return nil
        }
    }
}
