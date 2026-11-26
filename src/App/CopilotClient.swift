import Foundation
import Security

struct CopilotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CopilotProvider: String, CaseIterable, Identifiable {
    case openAI = "api", chatGPTPlan = "plan"
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI API key" : "ChatGPT account" }
}

/// Talks to the model. OpenAI API replies stream in as they're written; the ChatGPT plan returns whole replies.
enum CopilotClient {
    static let defaultModel = "gpt-5.1"
    static let suggestedModels = ["gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-4.1"]

    static func reply(provider: CopilotProvider, model: String, instructions: String, messages: [[String: String]],
                      onText: @escaping @MainActor (String) -> Void) async throws -> String {
        switch provider {
        case .chatGPTPlan:
            let text = try await ChatGPTPlan.ask(instructions: instructions, messages: messages)
            await onText(text)
            return text
        case .openAI:
            return try await streamOpenAI(model: model, instructions: instructions, messages: messages, onText: onText)
        }
    }

    private static func streamOpenAI(model: String, instructions: String, messages: [[String: String]],
                                     onText: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let key = CopilotKeychain.apiKey() else {
            throw CopilotError("Add your OpenAI API key in Copilot settings (the gear at the top right), or switch to your ChatGPT account there.")
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? defaultModel : model,
            "store": false,
            "stream": true,
            "instructions": instructions,
            "input": messages.map { ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""] },
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            throw failure(status: status, data: data)
        }
        var text = ""
        var lastPush = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                text += obj["delta"] as? String ?? ""
                if Date().timeIntervalSince(lastPush) > 0.05 { lastPush = Date(); let t = text; await onText(t) }
            case "response.failed", "error":
                let err = (obj["response"] as? [String: Any])?["error"] as? [String: Any] ?? obj["error"] as? [String: Any] ?? obj
                throw CopilotError("OpenAI: " + ((err["message"] as? String) ?? "the request failed."))
            case "response.incomplete":
                text += "\n\n_(Reply cut short by the model's output limit.)_"
            default: break
            }
        }
        await onText(text)
        guard !text.isEmpty else { throw CopilotError("OpenAI returned an empty reply. Try again.") }
        return text
    }

    static func failure(status: Int, data: Data) -> CopilotError {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String
        switch status {
        case 401: return CopilotError("OpenAI rejected the API key. Check it in Copilot settings.")
        case 429:
            let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? ""
            if code.contains("quota") || code.contains("credit") {
                return CopilotError("Your OpenAI account is out of API credit. Add credit at platform.openai.com → Billing, or switch to your ChatGPT account in Copilot settings.")
            }
            return CopilotError("OpenAI rate limit reached. Wait a few seconds and resend.")
        case 404: return CopilotError("OpenAI: " + (message ?? "model not found.") + " Pick another model in Copilot settings.")
        default: return CopilotError("OpenAI request failed (HTTP \(status))" + (message.map { ": " + $0 } ?? "."))
        }
    }
}

/// The OpenAI API key lives in the login Keychain. OPENAI_API_KEY in the environment also works.
enum CopilotKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "io.github.matt87-maker.OpenLinkTuner.OpenAI",
                                               kSecAttrAccount as String: "api-key"]

    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        var find = query
        find[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
