import Foundation

struct WebhookService {
    static func send(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let urlString = UserDefaults.standard.string(forKey: SettingsKeys.webhookURL),
              let url = URL(string: urlString) else {
            completion(.failure(WebhookError.noURL))
            return
        }

        let token = UserDefaults.standard.string(forKey: SettingsKeys.authToken) ?? ""

        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "text": text,
            "source": "voice-peter",
            "timestamp": formatter.string(from: Date()),
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(WebhookError.encodingFailed))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ... 299).contains(httpResponse.statusCode) {
                    completion(.failure(WebhookError.httpError(httpResponse.statusCode)))
                    return
                }
                completion(.success(()))
            }
        }.resume()
    }

    enum WebhookError: LocalizedError {
        case noURL
        case encodingFailed
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .noURL: "No webhook URL configured. Set it in the menu bar settings."
            case .encodingFailed: "Failed to encode request body."
            case .httpError(let code): "Webhook returned HTTP \(code)."
            }
        }
    }
}
