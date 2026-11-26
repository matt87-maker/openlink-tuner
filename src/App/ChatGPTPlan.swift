import Foundation
import Security

enum ChatGPTPlan {
    struct Result: Decodable {
        var sharing: Bool?
        var connected: Bool?
        var label: String?
        var text: String?
        var error: String?
    }

    private static func encryptionKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "io.github.matt87-maker.OpenLinkTuner.ChatGPTPlan",
                                    kSecAttrAccount as String: "credential-encryption-v1"]
        var find = query
        find[kSecReturnData as String] = true
        var item: CFTypeRef?
        let found = SecItemCopyMatching(find as CFDictionary, &item)
        if found == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard found == errSecItemNotFound else { throw CopilotError("Unlock the login Keychain to use your ChatGPT connection.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CopilotError("Could not create a storage key.") }
        var add = query
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return try encryptionKey() }
        guard status == errSecSuccess else { throw CopilotError("Could not save the connection’s encryption key to Keychain.") }
        return Data(bytes)
    }

    static func call(_ action: String, instructions: String = "", input: [[String: String]] = []) async throws -> Result {
        try await Task.detached {
            let fm = FileManager.default
            let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenLink Tuner")
            if action == "status", !fm.fileExists(atPath: support.appendingPathComponent("ChatGPT Account/chatgpt-auth.json").path) {
                return Result(sharing: false, connected: false)
            }
            guard let helper = Bundle.main.url(forResource: "chatgpt-plan", withExtension: "mjs"),
                  let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
                throw CopilotError("ChatGPT plan access needs Node.js 22.12 or later and the OpenLink sign-in helper.")
            }
            let payload: [String: Any] = ["action":action,"secret":try encryptionKey().base64EncodedString(),"instructions":instructions,"input":input]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let proc = Process(), request = Pipe(), response = Pipe()
            proc.executableURL = URL(fileURLWithPath: node)
            proc.arguments = [helper.path]
            proc.environment = ["HOME":fm.homeDirectoryForCurrentUser.path,"PATH":"/usr/bin:/bin"]
            proc.standardInput = request; proc.standardOutput = response; proc.standardError = FileHandle.nullDevice
            try proc.run()
            defer { if proc.isRunning { proc.terminate() } }
            try request.fileHandleForWriting.write(contentsOf: data)
            try request.fileHandleForWriting.close()
            let output = response.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, let result = try? JSONDecoder().decode(Result.self, from: output) else {
                throw CopilotError("The local ChatGPT plan helper could not complete this request.")
            }
            if let message = result.error { throw CopilotError(message) }
            return result
        }.value
    }

    /// Send one conversation turn through the signed-in ChatGPT plan. Returns the full reply text.
    static func ask(instructions: String, messages: [[String: String]]) async throws -> String {
        let result = try await call("ask", instructions: instructions, input: messages)
        guard let text = result.text, !text.isEmpty else { throw CopilotError("ChatGPT returned an empty reply. Try again.") }
        return text
    }
}
