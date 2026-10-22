import Foundation

enum AgentToolOutcome: String, Codable, Equatable, Sendable { case completed, failed, cancelled }

struct AgentPlanStep: Codable, Equatable, Sendable {
    let step: String
    let status: String
}

/// Versioned, local-only bridge protocol. No transcript, credentials or arbitrary
/// tool output crosses this boundary. Shared by the app and its native helper.
struct AgentHookEnvelope: Codable, Sendable {
    static let maximumBytes = 256 * 1024
    static let events: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop", "Interrupt",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"
    ]
    var version = 1
    var id = UUID().uuidString
    var sentAt = Date()
    var event: String
    var sessionID: String
    var turnID: String?
    var agentID: String?
    var toolID: String?
    var toolName: String?
    var title: String?
    var message: String?
    var command: String?
    var reason: String?
    var permissionMode: String?
    var threadSource: String?
    var parentThreadID: String?
    var reviewer: String?
    var cwd: String?
    var branch: String?
    var model: String?
    var userPrompt: String?
    var toolDetail: String?
    var toolOutcome: AgentToolOutcome?
    var plan: [AgentPlanStep]?
    var transcriptPath: String?

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    var isValid: Bool {
        version == 1 && Self.events.contains(event) && Self.validID(sessionID)
            && Self.validID(id) && turnID.map(Self.validID) != false
            && agentID.map(Self.validID) != false
            && parentThreadID.map(Self.validID) != false
            && parentThreadID != sessionID
            && sentAt.timeIntervalSince1970.isFinite
            && (command?.utf8.count ?? 0) <= 32_000
            && (message?.count ?? 0) <= 32_000 && (title?.count ?? 0) <= 160
            && [cwd, branch, model, toolDetail, transcriptPath].allSatisfy { ($0?.count ?? 0) <= 4000 }
            && (userPrompt?.count ?? 0) <= 8000
            && (plan?.count ?? 0) <= 20
            && (plan ?? []).allSatisfy { $0.step.count <= 200 && ["pending", "in_progress", "completed"].contains($0.status) }
    }

    static func decodeHook(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let sessionID = object["session_id"] as? String else { throw AgentHookWireError.invalidMessage }
        func text(_ value: Any?, limit: Int) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        let input = object["tool_input"] as? [String: Any]
        var result = Self(event: event, sessionID: sessionID)
        result.turnID = object["turn_id"] as? String
        result.agentID = object["agent_id"] as? String
        result.toolID = object["tool_use_id"] as? String
        result.toolName = text(object["tool_name"], limit: 160)
        result.title = text(object["prompt"], limit: 160)
        result.userPrompt = text(object["prompt"], limit: 8000)
        result.cwd = text(object["cwd"], limit: 4000)
        result.toolDetail = text(input?["command"] ?? input?["cmd"] ?? input?["file_path"] ?? input?["path"] ?? input?["pattern"] ?? input?["description"], limit: 4000)
        // Only explicit structured status is used; arbitrary tool output is
        // neither retained nor interpreted as success/failure.
        if event == "PostToolUse", let response = object["tool_response"] as? [String: Any] {
            if response["cancelled"] as? Bool == true { result.toolOutcome = .cancelled }
            else if response["is_error"] as? Bool == true || (response["exit_code"] as? Int).map({ $0 != 0 }) == true { result.toolOutcome = .failed }
        }
        if result.toolName?.split(separator: ".").last == "update_plan", let plan = input?["plan"] as? [[String: Any]] {
            result.plan = plan.prefix(20).compactMap {
                guard let step = text($0["step"], limit: 200), let status = $0["status"] as? String,
                      ["pending", "in_progress", "completed"].contains(status) else { return nil }
                return AgentPlanStep(step: step, status: status)
            }
        }
        result.message = text(object["last_assistant_message"], limit: 32_000)
        // A truncated command must never be offered for approval.
        if let command = input?["command"] as? String {
            guard command.utf8.count <= 32_000 else { throw AgentHookWireError.invalidMessage }
            result.command = command
        }
        result.reason = text(input?["description"], limit: 1000)
        result.permissionMode = text(object["permission_mode"], limit: 80)
        // stop_hook_active describes a previous Stop-hook continuation. It
        // does not promise that this invocation will continue after our reply.
        guard result.isValid else { throw AgentHookWireError.invalidMessage }
        return result
    }
}

enum AgentHookDecision: String, Codable, Sendable {
    case received, allow, deny, deferToApp

    /// Only PermissionRequest can carry a decision. Empty JSON has no policy
    /// effect and is also valid for Stop's JSON-only output contract.
    func hookOutput(for event: String) -> Data {
        guard event == "PermissionRequest", self == .allow || self == .deny else { return Data("{}\n".utf8) }
        let behavior = self == .allow ? "allow" : "deny"
        return Data("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"\(behavior)\"}}}\n".utf8)
    }
}

struct AgentHookReply: Codable, Sendable {
    var id: String
    var decision: AgentHookDecision
}

enum AgentHookWireError: Error { case invalidMessage, unavailable, timedOut, busy, unsafePath }
