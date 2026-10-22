import Foundation

/// Metadata from the followed parent, not a claim of independent child control
/// or a substitute for the synchronous native request/response protocol.
enum CodexDesktopExtras {
    static func spawnParent(_ source: [String: Any]?) -> String? {
        let modern = ((source?["subAgent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
        let legacy = ((source?["subagent"] as? [String: Any])?["spawn"] as? [String: Any])?["parent_thread_id"] as? String
        if let modern, let legacy, modern != legacy { return "" }
        return modern ?? legacy
    }

    static func children(items: [[String: Any]], parent: String, at date: Date?) -> [CodexPrimarySnapshot] {
        var found: [String: CodexPrimarySnapshot] = [:]
        for item in items where item["type"] as? String == "collabAgentToolCall" && item["senderThreadId"] as? String == parent {
            let receivers = item["receiverThreadIds"] as? [String] ?? []
            guard receivers.count <= 64 else { continue }
            if item["tool"] as? String == "spawnAgent", let entries = item["receiverThreads"] as? [[String: Any]], entries.count <= 32 {
                for entry in entries {
                    guard let id = entry["threadId"] as? String, UUID(uuidString: id) != nil, id != parent, receivers.contains(id),
                          let thread = entry["thread"] as? [String: Any], thread["id"] as? String == id,
                          thread["parentThreadId"] as? String == parent, spawnParent(thread["source"] as? [String: Any]) == parent else { continue }
                    var child = found[id] ?? CodexPrimarySnapshot(kind: .desktop, threadID: id)
                    child.parentThreadID = parent; child.classification = .subagent; child.status = .unknown
                    child.title = AgentMessagePreview.line(thread["agentNickname"] as? String ?? thread["title"] as? String) ?? String(id.prefix(8))
                    child.context.cwd = thread["cwd"] as? String; child.context.model = thread["model"] as? String
                    child.updatedAt = date; found[id] = child
                }
            }
            if let states = item["agentsStates"] as? [String: [String: Any]] {
                for id in receivers where found[id] != nil {
                    guard let value = states[id]?["status"] as? String else { continue }
                    let known: AgentActivityStatus
                    switch value {
                    case "running": known = .running
                    case "completed": known = .completed
                    case "errored", "error": known = .failed
                    case "interrupted": known = .cancelled
                    default: known = .unknown
                    }
                    found[id]?.context.lastKnownStatus = known
                }
            }
            if found.count > 32 { found = found.filter { Set(found.keys.sorted().prefix(32)).contains($0.key) } }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    static func asyncInput(items: [[String: Any]]) -> AgentPendingInput? {
        var pending: [AgentInputQuestion] = []
        for item in items {
            guard item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
                  let messageID = item["id"] as? String, AgentHookEnvelope.validID(messageID),
                  let questions = item["questions"] as? [[String: Any]], questions.count <= 8 else { continue }
            for (index, question) in questions.enumerated() {
                guard let text = CodexNativeRequests.text(question["title"], limit: 4_000),
                      let rawOptions = question["options"] as? [String], rawOptions.count <= 16,
                      rawOptions.allSatisfy({ CodexNativeRequests.text($0, limit: 1_000) != nil }),
                      let data = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", messageID, index], options: [.fragmentsAllowed]),
                      let id = String(data: data, encoding: .utf8), pending.count < 8 else { continue }
                pending.append(AgentInputQuestion(id: id, header: "", text: text, isSecret: false,
                    options: rawOptions.map { AgentInputOption(label: $0, description: "") }))
            }
        }
        guard !pending.isEmpty else { return nil }
        for item in items {
            let content: [[String: Any]]
            switch item["type"] as? String {
            case "userMessage": content = item["content"] as? [[String: Any]] ?? []
            case "steeringUserMessage" where item["status"] as? String == "accepted": content = item["input"] as? [[String: Any]] ?? []
            default: continue
            }
            for part in content where part["type"] as? String == "text" {
                guard let text = part["text"] as? String else { continue }
                for reply in replies(text) {
                    pending.removeAll { $0.id == reply.0 && $0.text == reply.1 }
                }
            }
        }
        guard let first = pending.first else { return nil }
        return AgentPendingInput(id: first.id, text: first.text, asynchronous: true, questions: pending, canRespond: false)
    }

    private static func replies(_ raw: String) -> [(String, String)] {
        let start = "<send_user_message_question_reply>", end = "</send_user_message_question_reply>"
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 64_000, text.hasPrefix(start), text.hasSuffix(end),
              let data = String(text.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        guard entries.count <= 8 else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["questionItemId"] as? String, let question = entry["question"] as? String, entry["answer"] is String else { return nil }
            return (id, question)
        }
    }
}
