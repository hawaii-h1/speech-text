// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AVFoundation

// MARK: - Helpers

/// A deinterleaved float32 buffer holding a sine, in every channel, at the format's rate.
private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount,
                            frequency: Double = 440, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channels = buffer.floatChannelData!
    for frame in 0 ..< Int(frames) {
        let sample = amplitude * Float(sin(2.0 * .pi * frequency * Double(frame) / format.sampleRate))
        for ch in 0 ..< Int(format.channelCount) {
            channels[ch][frame] = sample
        }
    }
    return buffer
}

private func mono48k() -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
}

private func int16Frames(_ data: Data) -> Int { data.count / MemoryLayout<Int16>.size }

private func int16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

// MARK: - PCMDownsampler

final class PCMDownsamplerTests: XCTestCase {

    func testDownsamples48kMonoByThree() throws {
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        let input = makeSineBuffer(format: mono48k(), frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input), "converter reported an error")
        if let tail = downsampler.flush() { pcm.append(tail) }

        // 48 kHz → 16 kHz is 3:1; the resampler's priming/delay line costs a few frames.
        let frames = int16Frames(pcm)
        XCTAssertEqual(frames, 1_600, accuracy: 64)

        // The waveform survives: a 0.5-amplitude sine should peak near 0.5 * Int16.max,
        // swinging both ways — not silence, not clipping, not a DC offset.
        let samples = int16Samples(pcm)
        XCTAssertGreaterThan(Int(samples.max() ?? 0), 10_000)
        XCTAssertLessThan(Int(samples.min() ?? 0), -10_000)
        XCTAssertLessThan(Int(samples.max() ?? 0), 22_000)
    }

    func testStereoDownmixesToMono() throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: stereo, targetRate: 16_000))
        let input = makeSineBuffer(format: stereo, frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input))
        if let tail = downsampler.flush() { pcm.append(tail) }

        // Mono output: the frame count follows the sample-rate ratio, not the channel
        // count — a channel-interleaving bug would double it.
        XCTAssertEqual(int16Frames(pcm), 1_600, accuracy: 64)
        XCTAssertGreaterThan(Int(int16Samples(pcm).max() ?? 0), 5_000)
    }

    func testConverterKeepsStateAcrossCalls() throws {
        // Two half-buffers through one converter must produce what one full buffer does:
        // the resampler's delay line carries samples across the call boundary.
        let whole = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var wholePCM = try XCTUnwrap(whole.convert(makeSineBuffer(format: mono48k(), frames: 4_800)))
        if let tail = whole.flush() { wholePCM.append(tail) }

        let halves = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var halvesPCM = Data()
        for _ in 0 ..< 2 {
            halvesPCM.append(try XCTUnwrap(halves.convert(makeSineBuffer(format: mono48k(), frames: 2_400))))
        }
        if let tail = halves.flush() { halvesPCM.append(tail) }

        XCTAssertEqual(int16Frames(halvesPCM), int16Frames(wholePCM), accuracy: 16)
    }
}

// MARK: - AudioBufferWriter

final class AudioBufferWriterTests: XCTestCase {

    func testWriteProducesReadable16kMonoFileOfExpectedDuration() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())

        // 1.0 s of audio, delivered in ten tap-sized buffers.
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }
        XCTAssertEqual(writer.bufferedDuration, 1.0, accuracy: 0.05)

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, AudioBufferWriter.preferredUploadCodec.fileExtension)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 1.0, accuracy: 0.05)
    }

    func testEmptyWriterThrowsNoAudio() {
        let writer = AudioBufferWriter()
        XCTAssertThrowsError(try writer.writeAudioFile()) { error in
            guard case AudioBufferWriter.AudioBufferWriterError.noAudio = error else {
                return XCTFail("expected noAudio, got \(error)")
            }
        }
    }

    func testSilentSegmentHasNoAudibleSignal() {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        }
        XCTAssertFalse(writer.hasAudibleSignal, "a −60 dBFS hum is a dead microphone, not speech")

        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.05))
        XCTAssertTrue(writer.hasAudibleSignal, "one quiet syllable is enough to upload")

        writer.reset()
        XCTAssertFalse(writer.hasAudibleSignal)
    }

    func testUnmeasuredNativeAudioCountsAsAudible() {
        // No `prepare`: the native fallback path has no converted samples to measure,
        // and the guard must not turn that into a skipped upload.
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        XCTAssertTrue(writer.hasAudibleSignal)
    }

    func testResetClearsBufferedAudio() {
        // No `prepare` — the native-copy fallback path, where reset() is fully
        // observable (the converter's delay line can't re-materialise frames).
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        XCTAssertEqual(writer.bufferedDuration, 0.1, accuracy: 0.001)

        writer.reset()
        XCTAssertEqual(writer.bufferedDuration, 0)
        XCTAssertThrowsError(try writer.writeAudioFile())
    }
}
