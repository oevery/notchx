import Foundation

/// Runs on the transport queue, before any pending main-queue delivery. Every
/// retained field is allowlisted and bounded; excluded payloads never queue.
enum CodexDaemonEventWire {
    static func sanitize(_ object: [String: Any], commentaryDelta: Bool) throws -> Data? {
        guard let method = object["method"] as? String else { return nil }
        if method.hasPrefix("item/reasoning/") || method.contains("outputDelta") || method.contains("patchUpdated")
            || method == "turn/diff/updated" || method == "item/plan/delta"
            || method.hasPrefix("thread/tokenUsage/") || method.hasPrefix("thread/readState/")
            || method.hasPrefix("thread/goal/") { return nil }
        if method == "item/agentMessage/delta" && !commentaryDelta { return nil }
        guard method.hasPrefix("thread/") || method.hasPrefix("turn/") || method.hasPrefix("item/") || method == "serverRequest/resolved" else { return nil }
        guard let source = object["params"] as? [String: Any] else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
        func fields(_ input: [String: Any], _ keys: [String], limit: Int = 256) -> [String: Any] {
            var result: [String: Any] = [:]
            for key in keys {
                if let string = input[key] as? String { result[key] = String(string.prefix(limit)) }
                else if let number = input[key] as? NSNumber { result[key] = number }
            }
            return result
        }
        func status(_ input: Any?) -> Any? {
            guard let input = input as? [String: Any] else { return input as? String }
            var result = fields(input, ["type"])
            if let flags = input["activeFlags"] as? [String] { result["activeFlags"] = Array(flags.prefix(16)).map { String($0.prefix(80)) } }
            return result
        }
        var params = fields(source, ["threadId", "turnId", "itemId", "threadName", "name"])
        if let value = status(source["status"]) { params["status"] = value }
        if let turn = source["turn"] as? [String: Any] { params["turn"] = fields(turn, ["id", "status", "startedAt", "completedAt"]) }
        if let thread = source["thread"] as? [String: Any] {
            var metadata = fields(thread, ["id", "sessionId", "parentThreadId", "source", "name", "cwd", "model", "updatedAt", "canAcceptDirectInput"])
            if let source = thread["source"] as? [String: Any] {
                if let parent = CodexDesktopExtras.spawnParent(source) {
                    metadata["source"] = ["subAgent": ["thread_spawn": ["parent_thread_id": String(parent.prefix(256))]]]
                } else { metadata["source"] = ["unsupported": true] }
            }
            if let nickname = thread["agentNickname"] as? String { metadata["agentNickname"] = String(nickname.prefix(256)) }
            if let value = status(thread["status"]) { metadata["status"] = value }
            params["thread"] = metadata
        }
        if let item = source["item"] as? [String: Any] {
            var safe = fields(item, ["id", "type", "status", "tool", "phase", "command", "query"])
            let type = item["type"] as? String
            if type == "agentMessage", item["phase"] as? String == "commentary", let text = item["text"] as? String { safe["text"] = String(text.prefix(240)) }
            if type == "userMessage", let content = item["content"] as? [[String: Any]] {
                guard content.count <= 64 else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
                safe["content"] = content.map { fields($0, ["type", "text"], limit: 1000) }
            }
            if type == "fileChange", let changes = item["changes"] as? [[String: Any]] {
                guard changes.count <= 64 else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
                safe["changes"] = changes.map { fields($0, ["path"]) }
            }
            if type == "collabAgentToolCall", let receivers = item["receiverThreadIds"] as? [String], receivers.count <= 80 {
                safe["receiverThreadIds"] = receivers.filter { UUID(uuidString: $0) != nil }
                if let sender = item["senderThreadId"] as? String { safe["senderThreadId"] = String(sender.prefix(256)) }
                if let states = item["agentsStates"] as? [String: [String: Any]], states.count <= 80 {
                    safe["agentsStates"] = states.filter { receivers.contains($0.key) }.mapValues { fields($0, ["status"], limit: 80) }
                }
            }
            params["item"] = safe
        }
        if method == "item/agentMessage/delta", let delta = source["delta"] as? String { params["delta"] = String(delta.prefix(240)) }
        if method == "turn/plan/updated", let plan = source["plan"] as? [[String: Any]] {
            guard plan.count <= 32 else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
            params["plan"] = plan.map { fields($0, ["step", "status"]) }
        }
        if method == "serverRequest/resolved", let id = CodexNativeRequestID(source["requestId"]) {
            params["requestId"] = id.wireValue
        }
        if method == "thread/settings/updated", let settings = source["threadSettings"] as? [String: Any] {
            params["threadSettings"] = fields(settings, ["approvalsReviewer"])
        }
        let nativeMethods = ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"]
        var envelope: [String: Any] = ["method": String(method.prefix(256))]
        if nativeMethods.contains(method), let id = CodexNativeRequestID(object["id"]) {
            envelope["id"] = id.wireValue
            // Keep request identity and explicit public UI fields intact. Do
            // not truncate native IDs or command/question text into new values.
            let keys = ["threadId", "turnId", "itemId", "command", "reason", "kind", "reviewer", "approvalsReviewer", "availableDecisions", "questions", "isBlocking", "grantRoot"]
            for key in keys where source[key] != nil { params[key] = source[key] }
            for key in ["networkApprovalContext", "additionalPermissions"] {
                if let value = source[key], !(value is NSNull) { params[key] = true }
            }
        }
        guard params["threadId"] is String || (params["thread"] as? [String: Any])?["id"] is String else {
            throw CodexDaemonConnection.Failure(submitted: false, code: nil)
        }
        envelope["params"] = params
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= 96 * 1024 else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
        return data
    }
}

/// One subscribed user's public display state. No reasoning, final answer,
/// output, diff, raw request or raw event history is retained.
@MainActor
struct CodexDaemonEventState {
    enum Change { case ignored, changed, unavailable }
    private(set) var snapshot: CodexPrimarySnapshot
    private(set) var eventCount = 0
    private(set) var subscribed = false
    private var blocked: CodexPrimaryCapabilities = []
    private var directInput: Bool
    private var retired: [String] = []
    private struct Tool { let id: String; let name: String; let detail: String? }
    private var tools: [Tool] = []
    private var completed: Set<String> = []
    private var commentary: Set<String> = []
    private var latestCommentaryID: String?
    private var queueAvailable = false
    private var childStates: [String: AgentActivityStatus] = [:]

    mutating func observeChild(_ child: CodexPrimarySnapshot) {
        guard child.kind == .daemon, child.classification == .subagent, child.parentThreadID == snapshot.threadID,
              child.threadID != snapshot.threadID, UUID(uuidString: child.threadID) != nil else { return }
        var summary = child
        summary.turnID = nil; summary.status = .unknown; summary.capabilities = []
        summary.context = AgentSessionContext()
        summary.context.cwd = child.context.cwd; summary.context.model = child.context.model
        summary.context.lastKnownStatus = child.context.lastKnownStatus ?? childStates[child.threadID]
        summary.observedChildren = []; summary.approvals = []; summary.approval = nil
        snapshot.observedChildren.removeAll { $0.threadID == child.threadID }
        snapshot.observedChildren.append(summary)
        snapshot.observedChildren = Array(snapshot.observedChildren.suffix(32))
    }

    mutating func setQueueAvailable(_ available: Bool) { queueAvailable = available; capabilities() }

    mutating func setRequests(approvals: [AgentApproval], input: AgentPendingInput?) {
        snapshot.approvals = approvals
        snapshot.approval = approvals.first
        snapshot.context.pendingInput = input
        capabilities()
    }

    init(snapshot: CodexPrimarySnapshot, turn: [String: Any]?, directInput: Bool) {
        self.snapshot = snapshot
        self.directInput = directInput
        self.snapshot.capabilities = []
        for item in (turn?["items"] as? [[String: Any]] ?? []).suffix(200) {
            let active = item["status"] as? String == "inProgress"
            applyItem(item, ending: !active)
        }
    }

    mutating func activate(directInput: Bool? = nil) {
        if let directInput { self.directInput = directInput }
        subscribed = true; capabilities()
    }

    /// Called only after a post-attach read barrier. Prefer the fresh page when
    /// no wire events raced it; otherwise preserve newer event state for this turn.
    mutating func rebase(_ fresh: CodexPrimarySnapshot, turn: [String: Any]?, eventsBeforeRead: Int) {
        if eventCount == eventsBeforeRead {
            let oldBlocked = blocked, oldRetired = retired, oldCount = eventCount, oldQueue = queueAvailable
            let children = snapshot.observedChildren, oldChildStates = childStates
            self = Self(snapshot: fresh, turn: turn, directInput: directInput)
            blocked.formUnion(oldBlocked); retired = oldRetired; eventCount = oldCount; queueAvailable = oldQueue
            childStates.merge(oldChildStates) { fresh, _ in fresh }
            for var child in children {
                child.context.lastKnownStatus = childStates[child.threadID] ?? child.context.lastKnownStatus
                observeChild(child)
            }
        } else if snapshot.turnID == fresh.turnID {
            snapshot.context.startedAt = snapshot.context.startedAt ?? fresh.context.startedAt
            snapshot.context.cwd = fresh.context.cwd
            snapshot.context.model = fresh.context.model
            snapshot.context.branch = fresh.context.branch
        } else if let incoming = fresh.context.startedAt, let current = snapshot.context.startedAt, incoming > current {
            let oldBlocked = blocked, oldCount = eventCount, oldQueue = queueAvailable
            self = Self(snapshot: fresh, turn: turn, directInput: directInput)
            blocked.formUnion(oldBlocked); eventCount = oldCount; queueAvailable = oldQueue
        } else {
            // Missing turn ordering proof must not retire a newer Hook turn.
            blocked.formUnion([.lifecycle, .messages, .tools, .progress, .plans])
        }
    }

    mutating func ingest(_ object: [String: Any]) -> Change {
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return .ignored }
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String
        guard thread == snapshot.threadID else { return .ignored }
        eventCount += 1
        switch method {
        case "thread/closed", "thread/archived", "thread/deleted": return .unavailable
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any],
                  let metadata = CodexDaemonChannel.normalize(thread: thread, turn: nil),
                  metadata.classification == snapshot.classification, metadata.parentThreadID == snapshot.parentThreadID else { return .unavailable }
            snapshot.title = metadata.title
        case "thread/status/changed":
            guard let status = params["status"] as? [String: Any], let type = status["type"] as? String else { return reject(.lifecycle) }
            if type == "notLoaded" { return .unavailable }
            guard ["active", "idle", "systemError"].contains(type) else { return reject(.lifecycle) }
            let flags = status["activeFlags"] as? [String] ?? []
            guard flags.allSatisfy({ ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) else { return reject(.lifecycle) }
            if flags.contains("waitingOnApproval") { snapshot.status = .waitingApproval }
            else if flags.contains("waitingOnUserInput") { snapshot.status = .waitingInput }
            else if type == "systemError" { snapshot.status = .failed }
            else if snapshot.status.isWaiting { snapshot.status = .running }
            // Idle can precede turn/completed. Do not fabricate a terminal turn.
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty,
                  turn["status"] as? String == "inProgress" else { return reject(.lifecycle) }
            if retired.contains(id) || (id == snapshot.turnID && snapshot.status.isTerminal) { return .ignored }
            if let incoming = CodexDaemonChannel.timestamp(turn["startedAt"]),
               let prior = snapshot.context.startedAt, incoming < prior { return .ignored }
            if id != snapshot.turnID {
                if let old = snapshot.turnID { retired = Array((retired + [old]).suffix(16)) }
                tools = []; completed = []; commentary = []; latestCommentaryID = nil
                let old = snapshot.context
                snapshot.context = AgentSessionContext()
                snapshot.context.cwd = old.cwd; snapshot.context.model = old.model; snapshot.context.branch = old.branch
            }
            snapshot.turnID = id; snapshot.status = .running
            snapshot.context.startedAt = CodexDaemonChannel.timestamp(turn["startedAt"]) ?? snapshot.context.startedAt
            snapshot.updatedAt = snapshot.context.startedAt ?? snapshot.updatedAt
            snapshot.activeToolID = nil; snapshot.activeToolName = nil
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return reject(.lifecycle) }
            guard id == snapshot.turnID else { return .ignored }
            switch turn["status"] as? String {
            case "completed": snapshot.status = .completed
            case "failed": snapshot.status = .failed
            case "interrupted": snapshot.status = .cancelled
            default: return reject(.lifecycle)
            }
            snapshot.updatedAt = CodexDaemonChannel.timestamp(turn["completedAt"]) ?? snapshot.updatedAt
            snapshot.activeToolID = nil; snapshot.activeToolName = nil
            snapshot.context.toolDetail = nil; snapshot.context.progressText = nil
            snapshot.context.latestActivity = nil; snapshot.context.lastCompletedTool = nil
            snapshot.context.pendingInput = nil; tools = []; completed = []; commentary = []; latestCommentaryID = nil
        case "item/started", "item/completed":
            guard let turn = params["turnId"] as? String, let item = params["item"] as? [String: Any] else { return reject([.tools, .messages, .progress]) }
            guard turn == snapshot.turnID, !snapshot.status.isTerminal else { return .ignored }
            applyItem(item, ending: method == "item/completed")
        case "item/agentMessage/delta":
            guard let turn = params["turnId"] as? String, let id = params["itemId"] as? String else { return reject(.progress) }
            guard turn == snapshot.turnID, !snapshot.status.isTerminal, commentary.contains(id), latestCommentaryID == id else { return .ignored }
            guard let delta = params["delta"] as? String else { return reject(.progress) }
            snapshot.context.progressText = AgentMessagePreview.line((snapshot.context.progressText ?? "") + String(delta.prefix(240)))
            if let text = snapshot.context.progressText { snapshot.context.latestActivity = .progress(text) }
        case "turn/plan/updated":
            guard let turn = params["turnId"] as? String else { return reject(.plans) }
            guard turn == snapshot.turnID, !snapshot.status.isTerminal else { return .ignored }
            guard let entries = params["plan"] as? [[String: Any]], entries.count <= 32 else { return reject(.plans) }
            var plan: [AgentPlanStep] = []
            for entry in entries {
                guard let step = AgentMessagePreview.line(entry["step"] as? String),
                      let status = entry["status"] as? String, ["pending", "inProgress", "completed"].contains(status) else { return reject(.plans) }
                plan.append(AgentPlanStep(step: step, status: status == "inProgress" ? "in_progress" : status))
            }
            snapshot.context.plan = plan
        case "item/tool/requestUserInput":
            guard params["turnId"] as? String == snapshot.turnID, !snapshot.status.isTerminal else { return .ignored }
            snapshot.status = .waitingInput
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            guard params["turnId"] as? String == snapshot.turnID, !snapshot.status.isTerminal else { return .ignored }
            snapshot.status = .waitingApproval
        case "serverRequest/resolved": break // Owner answers; status flags resolve the wait.
        case "thread/name/updated": snapshot.title = AgentMessagePreview.line(params["threadName"] as? String ?? params["name"] as? String) ?? snapshot.title
        default:
            // These categories carry deliberately excluded content or metadata.
            if method.hasPrefix("item/reasoning/") || method.contains("outputDelta") || method.contains("patchUpdated")
                || method == "turn/diff/updated" || method == "item/plan/delta"
                || method.hasPrefix("thread/tokenUsage/") || method.hasPrefix("thread/readState/")
                || method.hasPrefix("thread/goal/") { return .ignored }
            if method.hasPrefix("item/") { return reject([.tools, .messages, .progress]) }
            if method.hasPrefix("turn/") { return reject([.lifecycle, .plans]) }
            return .ignored
        }
        capabilities()
        return .changed
    }

    private mutating func reject(_ values: CodexPrimaryCapabilities) -> Change {
        blocked.formUnion(values); capabilities(); return .changed
    }

    private mutating func capabilities() {
        guard subscribed else { snapshot.capabilities = []; return }
        snapshot.capabilities = [.lifecycle, .tools, .messages, .progress, .plans]
        snapshot.capabilities.subtract(blocked)
        if directInput, !blocked.contains(.lifecycle) {
            if snapshot.status.isTerminal { snapshot.capabilities.insert(.send) }
            if snapshot.status == .running, snapshot.turnID != nil { snapshot.capabilities.insert(.steer) }
            if queueAvailable, snapshot.status == .running { snapshot.capabilities.insert(.queue) }
        }
        // Request-level interactivity is earned only from a validated native
        // handle; seeing a waiting status alone never earns this capability.
        if snapshot.context.pendingInput?.canRespond == true { snapshot.capabilities.insert(.questions) }
        if !snapshot.approvals.isEmpty { snapshot.capabilities.insert(.approvals) }
    }

    private mutating func applyItem(_ item: [String: Any], ending: Bool) {
        guard let type = item["type"] as? String else { blocked.formUnion([.tools, .messages, .progress]); return }
        if type == "collabAgentToolCall", item["senderThreadId"] as? String == snapshot.threadID,
           let receivers = item["receiverThreadIds"] as? [String], receivers.count <= 80,
           let states = item["agentsStates"] as? [String: [String: Any]], states.count <= 80 {
            for id in receivers where UUID(uuidString: id) != nil {
                guard let value = states[id]?["status"] as? String, childStates.count < 80 || childStates[id] != nil else { continue }
                let status: AgentActivityStatus
                switch value {
                case "running": status = .running
                case "completed": status = .completed
                case "errored", "error": status = .failed
                case "interrupted": status = .cancelled
                default: status = .unknown
                }
                childStates[id] = status
                if let index = snapshot.observedChildren.firstIndex(where: { $0.threadID == id }) {
                    snapshot.observedChildren[index].context.lastKnownStatus = status
                }
            }
        }
        if type == "userMessage" {
            guard let content = item["content"] as? [[String: Any]], content.count <= 64 else { blocked.insert(.messages); return }
            var text: [String] = []
            for entry in content {
                guard let kind = entry["type"] as? String else { blocked.insert(.messages); return }
                if kind == "text" {
                    guard let value = entry["text"] as? String else { blocked.insert(.messages); return }
                    text.append(String(value.prefix(1000)))
                } else if !["image", "localImage", "skill", "mention"].contains(kind) { blocked.insert(.messages) }
            }
            snapshot.context.prompt = AgentMessagePreview.userMessage(text.joined(separator: " "))
            snapshot.context.promptTurnID = snapshot.turnID
            return
        }
        if type == "agentMessage" {
            let phase = item["phase"] as? String
            if phase == "final_answer" { return }
            guard phase == "commentary" else { blocked.insert(.progress); return }
            guard let id = item["id"] as? String, let text = item["text"] as? String else { blocked.insert(.progress); return }
            if !commentary.contains(id) {
                guard commentary.count < 200 else { blocked.insert(.progress); return }
                commentary.insert(id); latestCommentaryID = id
            }
            guard latestCommentaryID == id else { return }
            snapshot.context.progressText = AgentMessagePreview.line(text)
            if let text = snapshot.context.progressText { snapshot.context.latestActivity = .progress(text) }
            return
        }
        if ["reasoning", "contextCompaction", "compaction", "imageView", "imageGeneration", "enteredReviewMode", "exitedReviewMode"].contains(type) { return }
        let name = type == "collabAgentToolCall" ? item["tool"] as? String : CodexDaemonChannel.toolName(type: type, item: item)
        guard let name, let id = item["id"] as? String, !id.isEmpty else { blocked.insert(.tools); return }
        let detail: String?
        switch type {
        case "commandExecution": detail = AgentMessagePreview.line(item["command"] as? String)
        case "fileChange": detail = AgentMessagePreview.line((item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String }.joined(separator: ", "))
        case "webSearch": detail = AgentMessagePreview.line(item["query"] as? String)
        default: detail = nil
        }
        if ending {
            guard !completed.contains(id) else { return }
            if completed.count < 256 { completed.insert(id) }
            tools.removeAll { $0.id == id }
            let status = item["status"] as? String
            guard status == nil || ["completed", "failed", "declined", "interrupted", "cancelled"].contains(status!) else { blocked.insert(.tools); return }
            let outcome: AgentToolOutcome = status == "failed" ? .failed : (["declined", "interrupted", "cancelled"].contains(status ?? "") ? .cancelled : .completed)
            snapshot.context.latestActivity = .completedTool(name: name, detail: detail, outcome: outcome)
            if let date = snapshot.updatedAt { snapshot.context.lastCompletedTool = AgentCompletedTool(name: name, detail: detail, finishedAt: date, outcome: outcome) }
        } else if !completed.contains(id) {
            guard tools.count < 32 else { blocked.insert(.tools); return }
            tools.removeAll { $0.id == id }; tools.append(Tool(id: id, name: name, detail: detail))
            snapshot.context.latestActivity = .tool(name: name, detail: detail)
        }
        snapshot.activeToolID = tools.last?.id; snapshot.activeToolName = tools.last?.name
        snapshot.context.toolDetail = tools.last?.detail
    }
}
