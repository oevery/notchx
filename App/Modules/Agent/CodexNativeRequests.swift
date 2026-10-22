import CoreFoundation
import Foundation

/// Preserve the JSON-RPC ID type. A string ID and a numeric ID with the same
/// spelling are different requests; neither is a thread or turn identifier.
enum CodexNativeRequestID: Equatable, Sendable {
    case string(String), number(Int64)

    init?(_ value: Any?) {
        if let string = value as? String, !string.isEmpty, string.utf8.count <= 256 { self = .string(string) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                let integer = Int64(number.stringValue), abs(number.doubleValue) <= 9_007_199_254_740_991 { self = .number(integer) }
        else { return nil }
    }

    var wireValue: Any { switch self { case .string(let value): return value; case .number(let value): return value } }
    var key: String {
        switch self {
        case .string(let value): return "s-" + Data(value.utf8).base64EncodedString()
        case .number(let value): return "n-" + String(value)
        }
    }
}

enum CodexNativeRequests {
    static func key(kind: CodexPrimaryChannelKind, thread: String, turn: String, id: CodexNativeRequestID) -> String {
        kind.rawValue + ":" + thread + ":" + turn + ":" + id.key
    }

    static func requestID(key: String, kind: CodexPrimaryChannelKind, thread: String, turn: String) -> CodexNativeRequestID? {
        let prefix = kind.rawValue + ":" + thread + ":" + turn + ":"
        guard key.hasPrefix(prefix) else { return nil }
        let value = String(key.dropFirst(prefix.count))
        if value.hasPrefix("s-"), let bytes = Data(base64Encoded: String(value.dropFirst(2))),
           let string = String(data: bytes, encoding: .utf8), let id = CodexNativeRequestID(string), id.key == value { return id }
        if value.hasPrefix("n-"), let number = Int64(value.dropFirst(2)), let id = CodexNativeRequestID(NSNumber(value: number)), id.key == value { return id }
        return nil
    }

    static func input(params: [String: Any], id: String) -> AgentPendingInput? {
        guard let raw = params["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 8 else { return nil }
        var questions: [AgentInputQuestion] = []
        for value in raw {
            guard let questionID = text(value["id"], limit: 256), !questions.contains(where: { $0.id == questionID }),
                  let question = text(value["question"], limit: 4_000),
                  let secret = value["isSecret"] as? Bool else { return nil }
            let rawOptions: [[String: Any]]
            if value["options"] == nil || value["options"] is NSNull { rawOptions = [] }
            else if let options = value["options"] as? [[String: Any]], options.count <= 16 { rawOptions = options }
            else { return nil }
            var options: [AgentInputOption] = []
            for option in rawOptions {
                guard let label = text(option["label"], limit: 1_000),
                      let description = option["description"] as? String, description.utf8.count <= 4_000 else { return nil }
                options.append(AgentInputOption(label: label, description: description))
            }
            let header = value["header"] as? String ?? ""
            guard header.utf8.count <= 1_000 else { return nil }
            var questionModel = AgentInputQuestion(id: questionID, header: header, text: question, isSecret: secret, options: options)
            questionModel.allowsOther = options.isEmpty || value["isOther"] as? Bool == true
            questions.append(questionModel)
        }
        return AgentPendingInput(id: id, text: questions[0].text, asynchronous: params["isBlocking"] as? Bool == false,
            questions: questions, canRespond: true)
    }

    static func approval(params: [String: Any], id: String) -> AgentApproval? {
        guard let thread = text(params["threadId"], limit: 256), let turn = text(params["turnId"], limit: 256),
              let command = text(params["command"], limit: 16_000),
              params["kind"] as? String == "command",
              params["reviewer"] == nil || params["reviewer"] is NSNull || params["reviewer"] as? String == "user",
              params["approvalsReviewer"] == nil || params["approvalsReviewer"] is NSNull || params["approvalsReviewer"] as? String == "user",
              params["availableDecisions"] == nil || params["availableDecisions"] is NSNull || params["availableDecisions"] is [Any],
              params["networkApprovalContext"] == nil || params["networkApprovalContext"] is NSNull,
              params["additionalPermissions"] == nil || params["additionalPermissions"] is NSNull else { return nil }
        // Do not reinterpret network/permission grants as an ordinary command.
        // Native callers additionally verify the request method/reviewer.
        var result = AgentApproval(id: id, sessionID: CodexAgentState.id(thread), turnID: turn, tool: "exec_command",
            command: command, reason: text(params["reason"], limit: 4_000), expiresAt: .distantFuture)
        if let values = params["availableDecisions"] as? [Any] {
            result.canAllow = values.contains { $0 as? String == "accept" }
            result.canDeny = values.contains { $0 as? String == "decline" }
            if !result.canDeny, values.contains(where: { $0 as? String == "cancel" }) {
                result.canDeny = true; result.denyEndsTurn = true
            }
        }
        return result.canAllow || result.canDeny ? result : nil
    }

    static func fileApproval(params: [String: Any], id: String, paths: [String]) -> AgentApproval? {
        guard let thread = text(params["threadId"], limit: 256), let turn = text(params["turnId"], limit: 256),
              params["grantRoot"] == nil || params["grantRoot"] is NSNull,
              !paths.isEmpty, paths.count <= 32, paths.allSatisfy({ text($0, limit: 4_000) != nil }),
              paths.joined(separator: "\n").utf8.count <= 16_000 else { return nil }
        return AgentApproval(id: id, sessionID: CodexAgentState.id(thread), turnID: turn, tool: "apply_patch",
            command: paths.joined(separator: "\n"), reason: text(params["reason"], limit: 4_000), expiresAt: .distantFuture)
    }

    static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit else { return nil }
        return value
    }
}
