import Foundation

/// Voice agent settings. The API key lives in the Keychain; the rest in UserDefaults
/// (read with @AppStorage in Settings, using the same keys).
enum VoiceSettings {
    private static let apiKeyAccount = "xai-api-key"

    static let voiceKey = "voiceAgentVoice"
    static let reasoningKey = "voiceAgentReasoning"
    static let idleHangUpKey = "voiceAgentIdleHangUp"

    /// Built-in xAI voices (docs list these three; more exist via GET /v1/tts/voices)
    static let voices = ["eve", "ara", "rex"]
    static let defaultVoice = "eve"

    /// xAI's `reasoning.effort`: "high" (its default) or "none" (faster)
    static let defaultReasoning = "high"

    static var apiKey: String? {
        KeychainHelper.getSecret(account: apiKeyAccount)
    }

    static var hasAPIKey: Bool {
        apiKey != nil
    }

    static func setAPIKey(_ key: String) throws {
        try KeychainHelper.saveSecret(key, account: apiKeyAccount)
    }

    static func removeAPIKey() {
        KeychainHelper.deleteSecret(account: apiKeyAccount)
    }

    static var voice: String {
        UserDefaults.standard.string(forKey: voiceKey) ?? defaultVoice
    }

    static var reasoning: String {
        UserDefaults.standard.string(forKey: reasoningKey) ?? defaultReasoning
    }

    static var idleHangUp: Bool {
        UserDefaults.standard.object(forKey: idleHangUpKey) as? Bool ?? true
    }

    /// Check a key against xAI without starting a (billed) voice session
    static func testAPIKey(_ key: String) async -> Result<String, Error> {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/api-key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard status == 200 else {
                let detail = json["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
                return .failure(VoiceKeyError.rejected("HTTP \(status) \(detail.prefix(120))"))
            }
            if json["api_key_blocked"] as? Bool == true || json["api_key_disabled"] as? Bool == true {
                return .failure(VoiceKeyError.rejected("The key is blocked or disabled"))
            }
            if json["team_blocked"] as? Bool == true {
                return .failure(VoiceKeyError.rejected("The key's team is blocked"))
            }
            let name = json["name"] as? String ?? ""
            return .success(name.isEmpty ? "Key works" : "Key works (\(name))")
        } catch {
            return .failure(error)
        }
    }
}

enum VoiceKeyError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let detail): return detail
        }
    }
}
