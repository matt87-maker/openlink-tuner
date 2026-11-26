import Foundation

// Tests the OpenAI streaming client against mock_openai.py (no key, no network). From the repository root:
//   python3 src/Tests/CopilotClient/mock_openai.py 8765 &
//   swiftc -o /tmp/client-check src/Tests/CopilotClient/main.swift src/App/CopilotClient.swift src/App/ChatGPTPlan.swift \
//     src/App/TuneCopilot.swift src/Shared/LogTable.swift src/Sources/OpenLinkKit/*.swift
//   OPENAI_BASE_URL=http://127.0.0.1:8765/v1 OPENAI_API_KEY=test-key /tmp/client-check
var failures = 0
func expect(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

func ask(_ model: String, onText: @escaping @MainActor (String) -> Void = { _ in }) async -> Result<String, Error> {
    do { return .success(try await CopilotClient.reply(provider: .openAI, model: model, instructions: "SYSTEM", messages: [["role": "user", "content": "fix my fuel"]], onText: onText)) }
    catch { return .failure(error) }
}

@MainActor final class Box { var updates: [String] = [] }
let box = await Box()
let ok = await ask("ok") { box.updates.append($0) }
let updates = await box.updates
if case .success(let text) = ok {
    let parsed = CopilotReply.parse(text)
    expect(parsed.changes.first?.op == "lambda_correct" && parsed.display.contains("| 2000 / 50 |") && !parsed.display.contains("```"), "streams a full reply; changes block parsed")
    expect(updates.count > 1 && updates.last == text, "text arrives in pieces while streaming (\(updates.count) updates)")
    expect(updates.allSatisfy { !CopilotReply.visible($0).contains("```changes") }, "the changes block never shows while streaming")
} else { expect(false, "streams a reply: \(ok)") }

let sent = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "src/Tests/CopilotClient/last_request.json"))) as! [String: Any]
let body = sent["body"] as! [String: Any]
expect(sent["auth"] as? String == "Bearer test-key", "sends the API key")
expect(body["stream"] as? Bool == true && body["store"] as? Bool == false && body["instructions"] as? String == "SYSTEM", "requests streaming, no storage, with the instructions")
expect((body["input"] as? [[String: String]])?.first?["content"] == "fix my fuel", "sends the conversation")

func message(_ r: Result<String, Error>) -> String { if case .failure(let e) = r { return e.localizedDescription }; return "no error" }
let bad = message(await ask("bad-key"))
expect(bad.contains("rejected the API key"), "401 → clear message: \(bad)")
let quota = message(await ask("quota"))
expect(quota.contains("out of API credit"), "429 quota → clear message: \(quota)")
let missing = message(await ask("missing"))
expect(missing.contains("does not exist") && missing.contains("Pick another model"), "404 → names the model problem: \(missing)")
let failed = message(await ask("fail"))
expect(failed.contains("The server had an error"), "failure mid-stream → error shown: \(failed)")

let slow = Task { await ask("slow") }
try? await Task.sleep(nanoseconds: 300_000_000)
slow.cancel()
let started = Date()
let cancelled = await slow.value
expect(Date().timeIntervalSince(started) < 2, "Stop cancels a streaming reply quickly")
if case .success = cancelled { expect(false, "cancelled reply should not complete") }

print(failures == 0 ? "\nALL CLIENT CHECKS PASSED" : "\n\(failures) CLIENT CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
