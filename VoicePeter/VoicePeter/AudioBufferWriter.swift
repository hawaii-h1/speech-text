import AVFoundation

final class AudioBufferWriter {
    private var buffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?

    func append(_ buffer: AVAudioPCMBuffer) {
        if format == nil {
            format = buffer.format
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let src = buffer.floatChannelData!
        let dst = copy.floatChannelData!
        for ch in 0 ..< Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        buffers.append(copy)
    }

    func writeWAV() throws -> URL {
        guard let format else {
            throw AudioBufferWriterError.noAudio
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        for buffer in buffers {
            try outputFile.write(from: buffer)
        }

        return tempURL
    }

    func reset() {
        buffers.removeAll()
        format = nil
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
