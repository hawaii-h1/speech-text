import AVFoundation
import os.log

private let abwLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeachText",
                             category: "AudioBufferWriter")

final class AudioBufferWriter {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else {
            abwLog.error("append: buffer has nil floatChannelData, skipping")
            return
        }
        guard buffer.frameLength > 0 else { return }

        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else {
            abwLog.error("append: failed to create copy buffer")
            return
        }
        copy.frameLength = buffer.frameLength

        guard let dst = copy.floatChannelData else {
            abwLog.error("append: copy buffer has nil floatChannelData")
            return
        }

        for ch in 0 ..< Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }

        lock.lock()
        if format == nil {
            format = buffer.format
        }
        buffers.append(copy)
        lock.unlock()
    }

    /// Speech-to-text APIs downsample to 16 kHz mono internally, so uploading the mic's
    /// native format (typically 48 kHz float32 ≈ 192 KB/s) wastes ~12x the bytes for no
    /// accuracy gain — and blows past provider upload limits after ~2 minutes of speech.
    private static let uploadSampleRate: Double = 16000

    func writeWAV() throws -> URL {
        lock.lock()
        let capturedFormat = format
        let capturedBuffers = buffers
        lock.unlock()

        dlog("Audio", "writeWAV: buffers=\(capturedBuffers.count), format=\(capturedFormat?.description ?? "nil")")

        guard let capturedFormat else {
            dlog("Audio", "writeWAV: no format — throwing noAudio")
            throw AudioBufferWriterError.noAudio
        }

        let totalFrames = capturedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        let duration = Double(totalFrames) / capturedFormat.sampleRate

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        // Downsample to 16 kHz mono Int16. Falls back to the native format if the
        // converter can't be built, so a conversion problem degrades to a big file
        // rather than losing the recording entirely.
        do {
            try Self.writeDownsampled(buffers: capturedBuffers, sourceFormat: capturedFormat, to: tempURL)
        } catch {
            dlog("Audio", "writeWAV: downsample failed (\(error.localizedDescription)) — falling back to native format")
            try? FileManager.default.removeItem(at: tempURL)
            try Self.writeNative(buffers: capturedBuffers, format: capturedFormat, to: tempURL)
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? nil
        dlog("Audio", "writeWAV: wrote \(totalFrames) frames (\(String(format: "%.1f", duration))s) → \(bytes.map { "\($0) bytes" } ?? "unknown size") at \(tempURL.lastPathComponent)")
        return tempURL
    }

    /// Total duration of the buffered audio, in seconds.
    var bufferedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let format else { return 0 }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        return Double(frames) / format.sampleRate
    }

    private static func writeDownsampled(buffers: [AVAudioPCMBuffer],
                                         sourceFormat: AVAudioFormat,
                                         to url: URL) throws {
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: uploadSampleRate,
                                               channels: 1,
                                               interleaved: true) else {
            throw AudioBufferWriterError.conversionFailed("could not create 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioBufferWriterError.conversionFailed("no converter from \(sourceFormat) to \(targetFormat)")
        }
        // Fold multi-channel input down to mono rather than just taking channel 0.
        converter.downmix = true

        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        var inputIndex = 0
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard inputIndex < buffers.count else {
                outStatus.pointee = .endOfStream
                return nil
            }
            let buffer = buffers[inputIndex]
            inputIndex += 1
            outStatus.pointee = .haveData
            return buffer
        }

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else {
                throw AudioBufferWriterError.conversionFailed("could not allocate output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError {
                throw AudioBufferWriterError.conversionFailed(conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && outBuffer.frameLength == 0 { break }
        }
    }

    private static func writeNative(buffers: [AVAudioPCMBuffer],
                                    format: AVAudioFormat,
                                    to url: URL) throws {
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        for buffer in buffers {
            try outputFile.write(from: buffer)
        }
    }

    func reset() {
        lock.lock()
        buffers.removeAll()
        format = nil
        lock.unlock()
    }

    static func cleanup(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    enum AudioBufferWriterError: LocalizedError {
        case noAudio
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio was recorded"
            case .conversionFailed(let reason): "Audio conversion failed: \(reason)"
            }
        }
    }
}
