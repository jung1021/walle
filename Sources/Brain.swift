import SwiftUI
import UIKit

/// Sends a captured frame to Claude's vision API and publishes the answer.
/// The API key is supplied by the caller (entered in the app, stored on-device),
/// never baked into the code or the repo.
@MainActor
final class Brain: ObservableObject {
    @Published var answer = ""
    @Published var isThinking = false
    @Published var error: String?

    func solve(image: UIImage, apiKey: String, model: String, prompt: String) async {
        guard !apiKey.isEmpty else { error = "Enter your Claude API key in Settings first."; return }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            error = "Couldn't encode the frame."
            return
        }

        isThinking = true
        error = nil
        answer = ""
        defer { isThinking = false }

        let base64 = jpeg.base64EncodedString()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                error = "No response from the server."
                return
            }
            guard http.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                error = "API error \(http.statusCode): \(detail)"
                return
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                answer = text.isEmpty ? "(Claude returned no text.)" : text
            } else {
                answer = String(data: data, encoding: .utf8) ?? "(Unparseable response.)"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
