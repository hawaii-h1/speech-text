// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Provider Type

enum STTProviderType: String, CaseIterable, Identifiable {
    case apple = "apple"
    case groq = "groq"
    case elevenlabs = "elevenlabs"
    case openai = "openai"
    case local = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple — on-device"
        case .groq: "Groq Whisper — cloud"
        case .elevenlabs: "ElevenLabs Scribe — cloud"
        case .openai: "OpenAI — cloud"
        case .local: "Local model — on your Mac"
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
            "Cloud Scribe. Strongest on accents and noisy audio, needs an API key. Scribe v2 Realtime shows text live while you speak; Scribe v2 only after you stop."
        case .openai:
            "Cloud GPT Transcribe. Needs an API key — the same one the AI rewrite uses. GPT Live Transcribe shows text live while you speak; the others only after you stop."
        case .local:
            "An open-source model — Parakeet or Whisper — downloaded to your Mac. Private, free, no key, works offline; text appears once you stop speaking."
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

    /// How long a stop made before the realtime session is ready waits for it. OpenAI's
    /// session transcribes nothing until `session.updated`, and a commit sent earlier
    /// finds an empty buffer — so `finish()` waits for it, flushes the audio held
    /// meanwhile, and only then commits. The handshake takes well under a second; past
    /// this the stream gives up and the stop uploads the file instead.
    static let streamSessionReadyTimeoutSeconds: Double = 3

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

    /// A segment whose loudest sample never reached this fraction of full scale
    /// (about −44 dBFS) is not uploaded. Whisper does not answer silence with nothing:
    /// it answers with "Thank you for watching" or "Дякую за перегляд", and that would
    /// be pasted. Peak rather than RMS, and deliberately low: one spoken syllable clears
    /// it by 20 dB even on a quiet microphone, so what it catches is a muted or dead
    /// input and a shortcut pressed with nothing said. Room noise above it still goes to
    /// the model. Chosen from the levels in the Debug Log, not from a measured corpus.
    static let silencePeakFloor: Float = 0.006

    /// A segment shorter than this is dropped without an upload, a History row or an
    /// error: it is a shortcut pressed and let go at once, or a pause the instant after a
    /// resume, not a word. 0.3 s is also about where a file becomes worth sending — one
    /// FLAC block (`AudioBufferWriter.flacBlockFrames`, 0.29 s) — and the measured 0.2 s
    /// segment that prompted this was answered with "Audio file might be corrupted" by
    /// OpenAI and could never be retried from History.
    static let minimumSegmentSeconds: Double = 0.3

    /// A segment no longer than this whose whole result is a known hallucination
    /// (`HallucinationFilter`) is kept as an empty result, its audio archived. Long
    /// enough for a shortcut pressed with a breath or a cough behind it; short enough
    /// that a real dictation of one of those phrases on its own is unlikely. A starting
    /// value, not a measurement: the audio corpus (#80) is what tunes it.
    static let hallucinationSegmentSeconds: Double = 2.0

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
/// the same snapshot. The realtime→scribe_v2 and Apple→Groq mappings live on
/// `RecordingConfiguration.batchModel`. The local tier goes through `LocalSTT` so this
/// file never names WhisperKit (it is compiled into the standalone test bundle).
func makeBatchProvider(configuration: RecordingConfiguration) -> BatchSTTProvider {
    switch configuration.provider {
    case .elevenlabs:
        ElevenLabsSTTProvider(apiKey: configuration.elevenLabsAPIKey, model: configuration.batchModel,
                              keyterms: configuration.batchVocabulary)
    case .openai:
        OpenAISTTProvider(apiKey: configuration.openAIAPIKey, model: configuration.batchModel,
                          keywords: configuration.batchVocabulary)
    case .groq, .apple:
        GroqSTTProvider(apiKey: configuration.groqAPIKey, model: configuration.batchModel,
                        prompt: Vocabulary.whisperPrompt(configuration.dictionary))
    case .local:
        LocalSTT.providerFactory(configuration.localModel)
    }
}

// MARK: - Groq Implementation

struct GroqSTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String
    /// Whisper's `prompt`: the Dictionary's words, so it spells them that way when it
    /// hears them (`Vocabulary.whisperPrompt`). Nil sends none.
    var prompt: String?

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = "whisper-large-v3-turbo", prompt: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
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
        if let prompt {
            body.appendMultipartField(boundary: boundary, name: "prompt", value: prompt)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("Groq", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("Groq", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        try validatedHTTPResponse(response, data: data, log: "Groq", label: "transcribe",
                                  bodyLimit: 200,
                                  nonHTTPMessage: "transcribe: invalid response (not HTTP)",
                                  invalidResponse: GroqError.invalidResponse,
                                  httpError: GroqError.httpError)

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
        case .httpError(let code, let body): providerErrorMessage(vendor: "Groq", status: code, body: body)
        }
    }
}

// MARK: - ElevenLabs Implementation

struct ElevenLabsSTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String
    /// The user's vocabulary, already fitted to this model (`RecordingConfiguration
    /// .batchVocabulary`). Empty sends no field at all.
    let keyterms: [String]

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = defaultElevenLabsModel, keyterms: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.keyterms = keyterms
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
        // The count only: terms are often people's names, and the log is public.
        dlog("ElevenLabs", "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil"), keyterms=\(keyterms.count)")

        request.httpBody = Self.multipartBody(boundary: boundary, audio: audioData, part: part,
                                              model: model, language: language, keyterms: keyterms)

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("ElevenLabs", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("ElevenLabs", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        try validatedHTTPResponse(response, data: data, log: "ElevenLabs", label: "transcribe",
                                  bodyLimit: 200,
                                  nonHTTPMessage: "transcribe: invalid response (not HTTP)",
                                  invalidResponse: ElevenLabsError.invalidResponse,
                                  httpError: ElevenLabsError.httpError)

        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        dlog("ElevenLabs", "transcribe: success, text=\(decoded.text.count) chars")
        return decoded.text
    }
}

extension ElevenLabsSTTProvider {
    /// The upload's form, apart so its fields can be tested without a request.
    static func multipartBody(boundary: String, audio: Data, part: (filename: String, mimeType: String),
                              model: String, language: String?, keyterms: [String]) -> Data {
        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audio)
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

        // A list field is the same name repeated, which is how the vendor's own SDK
        // sends it. +20 % on the transcription's price, so nothing unless there are terms.
        for term in keyterms {
            body.appendMultipartField(boundary: boundary, name: "keyterms", value: term)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
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
        case .httpError(let code, let body): providerErrorMessage(vendor: "ElevenLabs", status: code, body: body)
        case .realtime(let type, let detail): "ElevenLabs realtime \(type): \(detail)"
        }
    }
}

// MARK: - OpenAI Implementation

/// `POST /v1/audio/transcriptions` — the same multipart shape and Bearer auth as Groq,
/// whose endpoint is literally `api.groq.com/openai/v1/...`, but a separate type: the
/// reply carries a `languages` field Groq's does not, and `GroqError`'s text is shown
/// to the user ("Groq API error HTTP 401" under an OpenAI key would be a puzzle).
///
/// Uploads stay FLAC. OpenAI's documented format list (mp3, mp4, mpeg, mpga, m4a, wav,
/// webm) omits it, but the endpoint accepts it — verified with a real request on
/// 2026-09-21 against `gpt-transcribe` and `whisper-1`. Do not "fix" this to WAV on the
/// strength of the docs: WAV is twice the bytes against a 25 MB ceiling.
struct OpenAISTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String
    /// The user's vocabulary, already fitted to this model (`RecordingConfiguration
    /// .batchVocabulary`). Empty sends no field at all.
    let keywords: [String]

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = defaultOpenAISTTModel, keywords: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.keywords = keywords
    }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let part = multipartAudioPart(for: audioFileURL)
        // The count only: terms are often people's names, and the log is public.
        dlog("OpenAI", "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil"), keywords=\(keywords.count)")

        request.httpBody = Self.multipartBody(boundary: boundary, audio: audioData, part: part,
                                              model: model, language: language, keywords: keywords)

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("OpenAI", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("OpenAI", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        try validatedHTTPResponse(response, data: data, log: "OpenAI", label: "transcribe",
                                  bodyLimit: 200,
                                  nonHTTPMessage: "transcribe: invalid response (not HTTP)",
                                  invalidResponse: OpenAISTTError.invalidResponse,
                                  httpError: OpenAISTTError.httpError)

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        // The detected language is logged, never decoded into a typed field: the batch
        // reply spells it `[{"code":"uk"}]` and the realtime session `["uk"]`, and a
        // transcript must not be lost to a vendor changing the shape of a field the app
        // only prints. It is worth printing — this project shipped a data-loss bug from
        // forcing the keyboard layout's language on a cloud model, and on Auto this line
        // is the record of what the model decided instead.
        dlog("OpenAI", "transcribe: success, text=\(decoded.text.count) chars, detected=\(Self.detectedLanguages(in: data) ?? "?")")
        return decoded.text
    }

    /// The `languages` field as a log line, whatever shape it arrived in.
    private static func detectedLanguages(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["languages"] else { return nil }
        if let codes = raw as? [String] { return codes.joined(separator: ",") }
        if let objects = raw as? [[String: Any]] {
            return objects.compactMap { $0["code"] as? String }.joined(separator: ",")
        }
        return String(describing: raw)
    }
}

extension OpenAISTTProvider {
    /// The upload's form, apart so its fields can be tested without a request.
    static func multipartBody(boundary: String, audio: Data, part: (filename: String, mimeType: String),
                              model: String, language: String?, keywords: [String]) -> Data {
        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audio)
        body.appendMultipartField(boundary: boundary, name: "model", value: model)

        if let language {
            // `language` (singular) is what whisper-1 documents; gpt-transcribe documents
            // `languages` but accepts this one too and normalises it — verified against
            // the live endpoint, which answered `"languages":[{"code":"uk"}]` to it.
            let iso639 = String(language.prefix(2))
            body.appendMultipartField(boundary: boundary, name: "language", value: iso639)
        }

        // `keywords[]`, one field per term, as the vendor's guide writes it.
        for term in keywords {
            body.appendMultipartField(boundary: boundary, name: "keywords[]", value: term)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

enum OpenAISTTError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    /// The realtime socket reported an error, or sent something unusable.
    case realtime(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from OpenAI API"
        case .httpError(let code, let body): providerErrorMessage(vendor: "OpenAI", status: code, body: body)
        case .realtime(let code, let detail): "OpenAI realtime \(code): \(detail)"
        }
    }
}

// MARK: - Error text

/// A provider's error reply as a sentence the user can read. The reply body is JSON
/// written for developers (`{"error":{"message":…,"type":…,"param":…}}`), and it used to
/// be shown whole, braces and all; the Debug Log still has it verbatim. What is kept is
/// the provider's own message — the one part that says what went wrong — and the status,
/// so a History row stays traceable.
///
/// The shapes read are the three vendors': OpenAI and Groq nest it under
/// `error.message`, ElevenLabs under `detail.message` (or `detail` as a plain string,
/// or a list of validation failures).
/// A body with none of them falls back to what the status means.
func providerErrorMessage(vendor: String, status: Int, body: String) -> String {
    let reason = providerErrorReason(in: body) ?? genericReason(forStatus: status)
    let sentence = reason.last.map { ".!?".contains($0) } == true ? reason : reason + "."
    return "\(vendor) couldn't transcribe the recording: \(sentence) (HTTP \(status))"
}

private func providerErrorReason(in body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let candidates: [Any?] = [
        (json["error"] as? [String: Any])?["message"],
        json["error"],
        (json["detail"] as? [String: Any])?["message"],
        json["detail"],
        // A validation failure: `{"detail":[{"loc":…,"msg":…}]}`.
        (json["detail"] as? [[String: Any]])?.first?["msg"],
        json["message"],
    ]
    for case let text as String in candidates.compactMap({ $0 }) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
    }
    return nil
}

private func genericReason(forStatus status: Int) -> String {
    switch status {
    case 401, 403: "the API key was rejected"
    case 413: "the recording is too large"
    case 429: "too many requests — try again in a moment"
    case 500...: "the service is having problems"
    default: "the request was refused"
    }
}

// MARK: - HTTP Response Validation

/// The check every provider in this app runs on a JSON POST's reply: it must be an HTTP
/// response, and its status must be 2xx; anything else is logged with the body and turned
/// into that provider's own error.
///
/// One place rather than five near-identical copies. Each caller keeps its own log
/// category, message label and error type — only the shape is shared. Foundation only,
/// so the standalone test bundle still builds.
///
/// - Parameters:
///   - label: prefix for the log line, e.g. `"transcribe"` or the LLM's own label.
///   - bodyLimit: how much of the error body is logged.
///   - nonHTTPMessage: logged when the reply is not an HTTP response at all; nil logs nothing.
@discardableResult
func validatedHTTPResponse(_ response: URLResponse,
                           data: Data,
                           log category: String,
                           label: String,
                           bodyLimit: Int = 300,
                           nonHTTPMessage: String? = nil,
                           invalidResponse: Error,
                           httpError: (Int, String) -> Error) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        if let nonHTTPMessage { dlog(category, nonHTTPMessage) }
        throw invalidResponse
    }
    guard (200 ... 299).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "Unknown error"
        dlog(category, "\(label): HTTP \(http.statusCode): \(body.prefix(bodyLimit))")
        throw httpError(http.statusCode, body)
    }
    return http
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
