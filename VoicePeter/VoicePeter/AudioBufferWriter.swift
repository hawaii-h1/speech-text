import AVFoundation
import os.log

private let abwLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoicePeter",
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

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: capturedFormat.settings,
            commonFormat: capturedFormat.commonFormat,
            interleaved: capturedFormat.isInterleaved
        )

        for buffer in capturedBuffers {
            try outputFile.write(from: buffer)
        }

        let totalFrames = capturedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        let duration = Double(totalFrames) / capturedFormat.sampleRate
        dlog("Audio", "writeWAV: wrote \(totalFrames) frames (\(String(format: "%.1f", duration))s) to \(tempURL.lastPathComponent)")
        return tempURL
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

        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio was recorded"
            }
        }
    }
}
