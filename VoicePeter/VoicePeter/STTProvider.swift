import Foundation

// MARK: - Provider Type

enum STTProviderType: String, CaseIterable, Identifiable {
    case apple = "apple"
    case groq = "groq"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple — on-device"
        case .groq: "Groq Whisper — cloud"
        }
    }

    /// One-line explanation shown under the engine picker in Settings.
    var subtitle: String {
        switch self {
        case .apple:
            "Runs on your Mac. Free, private, shows text live while you speak."
        case .groq:
            "Cloud Whisper. Usually more accurate, needs an API key, and text only appears once you stop speaking."
        }
    }

    var supportsLiveText: Bool {
        switch self {
        case .apple: true
        case .groq: false
        }
    }
}

// MARK: - Batch STT Protocol

protocol BatchSTTProvider {
    func transcribe(audioFileURL: URL, language: String?) async throws -> String
}

// MARK: - Groq Implementation

struct GroqSTTProvider: BatchSTTProvider {
    let apiKey: String
    let model: String

    /// Custom URLSession with a 120s timeout — URLSession.shared ignores
    /// URLRequest.timeoutInterval and enforces its own 60s default.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
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
        dlog("Groq", "transcribe: audioSize=\(audioData.count) bytes, model=\(model), language=\(language ?? "nil")")

        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: "recording.wav", mimeType: "audio/wav",
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
