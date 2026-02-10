import Foundation

// MARK: - Provider Type

enum STTProviderType: String, CaseIterable, Identifiable {
    case apple = "apple"
    case groq = "groq"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple (On-Device)"
        case .groq: "Groq Whisper"
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
        request.timeoutInterval = 120

        let audioData = try Data(contentsOf: audioFileURL)
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroqError.httpError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
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
