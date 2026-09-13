// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Provider Type

enum STTProviderType: String, CaseIterable, Identifiable {
    case apple = "apple"
    case groq = "groq"
    case elevenlabs = "elevenlabs"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple — on-device"
        case .groq: "Groq Whisper — cloud"
        case .elevenlabs: "ElevenLabs Scribe — cloud"
        }
    }

    /// One-line explanation shown under the engine picker in Settings.
    var subtitle: String {
        switch self {
        case .apple:
            "Runs on your Mac. Free, private, shows text live while you speak."
        case .groq:
            "Cloud Whisper. Usually more accurate, needs an API key, and text only appears once you stop speaking."
        case .elevenlabs:
            "Cloud Scribe. Strongest on accents and noisy audio, needs an API key. Scribe v2 Realtime shows text live while you speak; the v1 models only after you stop."
        }
    }
}

// MARK: - Tuning

/// Every latency and quality knob the cloud STT providers use, in one place, so a value
/// measured against the live service is not re-derived by feel in two files. All of
/// these were verified by probing the ElevenLabs API on 2026-08-29.
enum STTTuning {
    /// Seconds of silence after which Scribe Realtime's VAD commits a segment. The
    /// server default is 1.5 s, sized for conversational turns; a dictation pause is
    /// shorter, and every tenth of a second here is a tenth the user waits before the
    /// text can be inserted. Below ~1 s the VAD starts splitting mid-sentence hesitations.
    static let vadSilenceThresholdSeconds: Double = 1.0

    /// How long `finish()` waits for the transcript of its final commit before pasting
    /// what it has. Scribe normally answers well inside a second; this only bounds the
    /// wait when the server is slow or the reply is lost, so the paste can never hang.
    static let streamFinishTimeoutSeconds: Double = 4

    /// Size of each audio message on the socket. The tap delivers ~20 ms buffers, and a
    /// WebSocket frame per buffer is mostly overhead; 100 ms keeps the first partial
    /// arriving quickly without flooding the connection.
    static let streamChunkSeconds: Double = 0.1

    /// Silence appended to the last chunk sent with `commit: true`. The server ignores
    /// a commit with under 0.3 s of uncommitted audio (`commit_throttled`), so 0.4 s
    /// guarantees the commit is honoured and adds nothing to the transcript.
    static let streamCommitPaddingSeconds: Double = 0.4

    /// Upper bound on audio held client-side while the socket is still handshaking
    /// (`session_started` not yet seen). Ten seconds is far more than a TLS handshake
    /// takes; if it fills, the stream gives up (`.failed`) rather than dropping the
    /// oldest audio and later reporting a transcript with the opening seconds missing
    /// as a success — the batch fallback has the full recording on disk.
    static let streamPreSessionBufferSeconds: Double = 10

    /// How long `finish()` keeps listening after a `committed_transcript` arrives before
    /// treating it as the reply to its own commit. The server answers in order, so if
    /// the VAD had just closed an earlier segment when the user stopped, that segment's
    /// transcript lands first and the final one — preceded by its `partial_transcript`s —
    /// is still on its way; closing on the first would drop the last phrase without any
    /// failure to trigger the batch fallback. A partial arriving inside this window
    /// re-arms the wait. Measured replies for a padded commit are well under this.
    static let streamCommitGraceSeconds: Double = 0.2

    /// Batch upload timeouts. `URLSession.shared` ignores `URLRequest.timeoutInterval`
    /// and enforces its own 60 s default, which a multi-minute FLAC can exceed. 120 s
    /// per request covers a stalled response; 300 s for the whole resource covers a
    /// slow upload of a long recording.
    static let batchRequestTimeoutSeconds: TimeInterval = 120
    static let batchResourceTimeoutSeconds: TimeInterval = 300

    /// Quality flags for Scribe. `tag_audio_events` defaults to *true* on the API, which
    /// would put "(laughs)" and "(door closes)" into pasted text, so it is sent off
    /// explicitly. `no_verbatim` drops fillers and false starts server-side — the point
    /// of dictation is the words the user meant, not the ones they stumbled over. The
    /// docs say it is only honoured by scribe_v2; scribe_v1 accepts and ignores it.
    static let tagAudioEvents = false
    static let noVerbatim = true
}

// MARK: - Batch STT Protocol

protocol BatchSTTProvider {
    func transcribe(audioFileURL: URL, language: String?) async throws -> String
}

/// The multipart filename and MIME type for an upload, read off the file's extension.
/// `AudioBufferWriter` decides the container (FLAC normally, WAV as its fallback) and
/// History keeps whatever it was handed, so the providers must not assume either: a
/// `.wav` archived before FLAC uploads existed has to retry as a WAV. The filename
/// matters too — Groq sniffs the extension when the MIME type is ambiguous.
func multipartAudioPart(for fileURL: URL) -> (filename: String, mimeType: String) {
    let ext = fileURL.pathExtension.lowercased()
    switch ext {
    case "flac": return ("recording.flac", "audio/flac")
    case "wav", "": return ("recording.wav", "audio/wav")
    default: return ("recording.\(ext)", "audio/\(ext)")
    }
}

/// Builds a batch provider for a session's configuration. Shared by the live
/// recording path, the streaming fallback and History retries, so all three honour
/// the same snapshot. The realtime→scribe_v1 and Apple→Groq mappings live on
/// `RecordingConfiguration.batchModel`.
func makeBatchProvider(configuration: RecordingConfiguration) -> BatchSTTProvider {
    switch configuration.provider {
    case .elevenlabs:
        ElevenLabsSTTProvider(apiKey: configuration.elevenLabsAPIKey, model: configuration.batchModel)
    case .groq, .apple:
        GroqSTTProvider(apiKey: configuration.groqAPIKey, model: configuration.batchModel)
    }
}

// MARK: - Groq Implementation

struct GroqSTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = "whisper-large-v3-turbo") {
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let part = multipartAudioPart(for: audioFileURL)
        dlog("Groq", "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil")")

        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audioData)
        body.appendMultipartField(boundary: boundary, name: "model", value: model)
        body.appendMultipartField(boundary: boundary, name: "response_format", value: "json")

        if let language {
            let iso639 = String(language.prefix(2))
            body.appendMultipartField(boundary: boundary, name: "language", value: iso639)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("Groq", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("Groq", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse else {
            dlog("Groq", "transcribe: invalid response (not HTTP)")
            throw GroqError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            dlog("Groq", "transcribe: HTTP error \(httpResponse.statusCode): \(errorBody.prefix(200))")
            throw GroqError.httpError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
        dlog("Groq", "transcribe: success, text=\(decoded.text.count) chars")
        return decoded.text
    }
}

private struct GroqTranscriptionResponse: Decodable {
    let text: String
}

enum GroqError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Groq API"
        case .httpError(let code, let body): "Groq API error HTTP \(code): \(body)"
        }
    }
}

// MARK: - ElevenLabs Implementation

struct ElevenLabsSTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = "scribe_v1") {
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let part = multipartAudioPart(for: audioFileURL)
        dlog("ElevenLabs", "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil")")

        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audioData)
        body.appendMultipartField(boundary: boundary, name: "model_id", value: model)
        // Quality flags — see `STTTuning`. Both are accepted by every batch model ID
        // (verified against scribe_v1 and scribe_v2).
        body.appendMultipartField(boundary: boundary, name: "tag_audio_events",
                                  value: STTTuning.tagAudioEvents ? "true" : "false")
        body.appendMultipartField(boundary: boundary, name: "no_verbatim",
                                  value: STTTuning.noVerbatim ? "true" : "false")

        if let language {
            let iso639 = String(language.prefix(2))
            body.appendMultipartField(boundary: boundary, name: "language_code", value: iso639)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("ElevenLabs", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("ElevenLabs", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse else {
            dlog("ElevenLabs", "transcribe: invalid response (not HTTP)")
            throw ElevenLabsError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            dlog("ElevenLabs", "transcribe: HTTP error \(httpResponse.statusCode): \(errorBody.prefix(200))")
            throw ElevenLabsError.httpError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        dlog("ElevenLabs", "transcribe: success, text=\(decoded.text.count) chars")
        return decoded.text
    }
}

private struct ElevenLabsTranscriptionResponse: Decodable {
    let text: String
}

enum ElevenLabsError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    /// A `message_type` other than a transcript arrived on the realtime socket.
    case realtime(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from ElevenLabs API"
        case .httpError(let code, let body): "ElevenLabs API error HTTP \(code): \(body)"
        case .realtime(let type, let detail): "ElevenLabs realtime \(type): \(detail)"
        }
    }
}

// MARK: - Multipart Helpers

extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
