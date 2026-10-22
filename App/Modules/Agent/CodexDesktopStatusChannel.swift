import CoreFoundation
import Darwin
import Foundation

/// Follows existing Desktop owners only. A router handshake never earns
/// coverage; a recognized, revision-consistent thread snapshot does.
@MainActor
final class CodexDesktopStatusChannel: CodexPrimaryChannel {
    let kind = CodexPrimaryChannelKind.desktop
    private let root: URL
    private var generation: UInt64 = 0
    private var worker: CodexDesktopStatusWorker?
    private var receive: (@MainActor (CodexPrimaryChannelUpdate) -> Void)?
    private var covered: [String: CodexPrimarySnapshot] = [:]
    private var roots: Set<String> = []
    private var deliveredSequence: UInt64 = 0
    private var pendingSend: Task<AgentMessageDelivery, Never>?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.root = root }
    deinit { worker?.cancel(); pendingSend?.cancel() }

    func start(threads: Set<String>, receive: @escaping @MainActor (CodexPrimaryChannelUpdate) -> Void) {
        stop()
        self.receive = receive
        roots = threads
        deliveredSequence = 0
        let token = generation
        let worker = CodexDesktopStatusWorker(root: root, threads: threads) { [weak self] sequence, update in
            // FIFO on the main queue preserves withdrawal-before-recovery;
            // the sequence guard also rejects a stale queued callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.worker != nil, sequence > self.deliveredSequence else { return }
                self.deliveredSequence = sequence
                switch update {
                case .snapshot(let snapshot):
                    guard self.includes(snapshot.threadID, parent: snapshot.parentThreadID) else { return }
                    self.covered[snapshot.threadID] = snapshot
                case .unavailable(_, let threads): for thread in threads { self.covered.removeValue(forKey: thread) }
                }
                self.receive?(update)
            }
        }
        self.worker = worker
        worker.start()
    }

    func updateThreads(_ threads: Set<String>) {
        roots = threads
        let removed = Set(covered.keys.filter { !includes($0, parent: covered[$0]?.parentThreadID) })
        for thread in removed { covered.removeValue(forKey: thread) }
        if !removed.isEmpty { receive?(.unavailable(.desktop, removed)) }
        worker?.updateThreads(threads)
    }

    private func includes(_ thread: String, parent: String?) -> Bool {
        if roots.contains(thread) { return true }
        var cursor = parent
        for _ in 0..<8 {
            guard let id = cursor else { return false }
            if roots.contains(id) { return true }
            cursor = covered[id]?.parentThreadID
        }
        return false
    }

    func stop() {
        generation &+= 1
        worker?.cancel(); worker = nil
        pendingSend?.cancel(); pendingSend = nil
        let removed = Set(covered.keys)
        covered.removeAll(); roots.removeAll()
        let callback = receive; receive = nil
        if !removed.isEmpty { callback?(.unavailable(.desktop, removed)) }
    }

    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery {
        guard let state = covered[request.sessionID.sessionID], let owner = state.ownerID,
              state.turnID == request.turnID, state.capabilities.contains(request.mode.capability) else { return .failed }
        return await perform { [root] in await CodexDesktopTransport.send(request, root: root, owner: owner) }
    }

    func respondToInput(_ response: AgentInputResponse) async -> AgentMessageDelivery {
        guard let state = covered[response.sessionID.sessionID], state.turnID == response.turnID,
              let input = state.context.pendingInput, response.matches(input), let owner = state.ownerID else { return .failed }
        return await perform { [root] in await CodexDesktopTransport.respondToInput(response, input: input, owner: owner, root: root) }
    }

    func respond(approval: AgentApproval, decision: AgentHookDecision) async -> AgentMessageDelivery {
        guard let state = covered[approval.sessionID.sessionID], state.turnID == approval.turnID,
              state.approvals.contains(where: { $0.id == approval.id }), let owner = state.ownerID,
              decision == .allow && approval.canAllow || decision == .deny && approval.canDeny else { return .failed }
        return await perform { [root] in await CodexDesktopTransport.respond(approval: approval, decision: decision, owner: owner, root: root) }
    }

    private func perform(_ operation: @escaping @MainActor () async -> AgentMessageDelivery) async -> AgentMessageDelivery {
        guard worker != nil, pendingSend == nil, !Task.isCancelled else { return .failed }
        let token = generation
        let task = Task { await operation() }
        pendingSend = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token { pendingSend = nil }
        // A write may have reached Desktop even if stop invalidated coverage.
        return generation == token ? result : result == .failed ? .failed : .uncertain
    }
}

enum CodexDesktopStreamResult {
    case ignored, resubscribe, snapshot(CodexPrimarySnapshot)
}

/// Worker-confined state. Sensitive text is removed before it is cached.
/// Unknown protocol shapes fail closed instead of disabling fallback hooks.
struct CodexDesktopStreamState {
    let thread: String
    let owner: String
    var expectedParent: String?
    private(set) var revision: Int64?
    private var retained: CodexDesktopRetainedDocument?
    var document: [String: Any]? { retained?.projection }
    var retainedBytes: Int { retained?.retainedBytes ?? 0 }
    var filteredNodeCount: Int { retained?.filteredNodeCount ?? 0 }
    private var revisionFloor: Int64 = 0

    init(thread: String, owner: String, expectedParent: String? = nil) {
        self.thread = thread; self.owner = owner; self.expectedParent = expectedParent
    }

    mutating func consume(_ message: [String: Any]) -> CodexDesktopStreamResult {
        guard message["type"] as? String == "broadcast",
              message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any], params["conversationId"] as? String == thread,
              message["sourceClientId"] as? String == owner else { return .ignored }
        guard CodexDesktopProjection.integer(message["version"]) == 11, params["hostId"] as? String == "local",
              let change = params["change"] as? [String: Any],
              let next = CodexDesktopProjection.integer(change["revision"]), next >= 0 else { return reset() }
        if next < revisionFloor { return .ignored }
        if let revision, next <= revision { return .ignored }
        var candidate: CodexDesktopRetainedDocument
        if change["type"] as? String == "snapshot" {
            guard let state = change["conversationState"] as? [String: Any] else { return reset() }
            do { candidate = try CodexDesktopRetainedDocument(state) }
            catch { return reset() }
        } else if change["type"] as? String == "patches" {
            guard let revision, let retained,
                  CodexDesktopProjection.integer(change["baseRevision"]) == revision,
                  revision < Int64.max, next == revision + 1,
                  let patches = change["patches"] as? [[String: Any]], patches.count <= 512 else { return reset() }
            candidate = retained
            do { try candidate.apply(patches) }
            catch { return reset() }
        } else { return reset() }
        guard let filtered = candidate.projection,
              var snapshot = CodexDesktopProjection.snapshot(filtered, thread: thread, parent: expectedParent, revision: next) else { return reset() }
        snapshot.ownerID = owner
        if let textChanges = change["acceptedTextChanges"] {
            guard let array = textChanges as? [Any] else { return reset() }
            // Supplemental text-buffer deltas are not yet a verified
            // parser contract; keep their fallback observations enabled.
            if !array.isEmpty { snapshot.capabilities.subtract([.messages, .progress]) }
        }
        retained = candidate; revision = next; revisionFloor = next
        return .snapshot(snapshot)
    }

    mutating func reset() -> CodexDesktopStreamResult { retained = nil; revision = nil; return .resubscribe }

    var childCandidates: Set<String> {
        guard let document, let turns = CodexDesktopProjection.turns(document) else { return [] }
        // Activity links are candidates, not proof of parentage. The child's
        // own snapshot must confirm parentThreadId before it is published.
        return Set(turns.suffix(1).flatMap { ($0["items"] as? [[String: Any]] ?? []).flatMap { item -> [String] in
            let candidates: [String]
            if item["type"] as? String == "subAgentActivity" { candidates = (item["agentThreadId"] as? String).map { [$0] } ?? [] }
            else if item["type"] as? String == "collabAgentToolCall" { candidates = item["receiverThreadIds"] as? [String] ?? [] }
            else { return [] }
            return candidates.filter { UUID(uuidString: $0) != nil && $0 != thread }
        } })
    }
}

enum CodexDesktopProjection {
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }

    static let roots: Set<String> = ["id", "hostId", "parentThreadId", "source", "threadSource", "title", "cwd",
        "gitInfo", "latestModel", "latestCollaborationMode", "updatedAt", "resumeState", "threadRuntimeStatus",
        "turns", "turnHistory", "requests"]
    private static let metadata: Set<String> = ["id", "type", "kind", "status", "phase", "role", "hostId", "parentThreadId",
        "parent_thread_id", "threadSource", "title", "cwd", "branch", "model", "latestModel", "resumeState",
        "updatedAt", "turnId", "threadId", "itemId", "entityKey", "key", "agentThreadId", "turnStartedAtMs",
        "completedAtMs", "durationMs", "requestId", "method", "completed", "exitCode",
        "isSecret", "isOther", "isBlocking", "approvalId", "startedAtMs", "approvalsReviewer",
        "delivery", "senderThreadId", "agentNickname"]
    private static let toolFields: Set<String> = ["command", "cmd", "name", "tool", "server", "path", "query", "pattern", "file_path"]
    static let sensitive: Set<String> = ["output", "aggregatedOutput", "stdout", "stderr", "result", "results", "rawOutput",
        "diff", "summary", "encryptedContent", "encrypted_content", "reasoning", "reasoningSummary", "reasoningContent"]

    /// Preserve collection shape for patch indices, but not hidden text. A
    /// reasoning/output subtree can never re-enable text through a nested type.
    static func filter(_ value: Any, path: [String] = [], item: String? = nil, publicText: Bool = false,
                       redacted: Bool = false, budget: inout Int) throws -> Any {
        budget -= 1
        guard budget >= 0, path.count <= 48 else { throw AgentHookWireError.invalidMessage }
        // Bodies outside the projection are opaque, not recursively retained
        // empty-string copies of potentially enormous output/history trees.
        if redacted { return NSNull() }
        if let object = value as? [String: Any] {
            var item = item, publicText = publicText
            if path.last == "[]", path.dropLast().last == "items", let type = object["type"] as? String {
                item = type; publicText = type == "userMessage" || type == "steeringUserMessage"
                    || type == "agentMessage" && object["phase"] as? String == "commentary"
            }
            var result: [String: Any] = [:]
            for (key, child) in object {
                let blocked = redacted || sensitive.contains(key) || path.isEmpty && !roots.contains(key)
                result[key] = blocked ? NSNull() : try filter(child, path: path + [key], item: item, publicText: publicText, budget: &budget)
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try filter($0, path: path + ["[]"], item: item, publicText: publicText, redacted: redacted, budget: &budget) }
        }
        let key = path.last ?? ""
        let question = path.contains("questions") && ["question", "header", "label", "description"].contains(key)
        let text = key == "text" && publicText
        let plan = key == "step" && (path.contains("plan") || item == "plan")
        let tool = toolFields.contains(key) && ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"].contains(item ?? "")
        let collaboration = item == "collabAgentToolCall" && key == "tool"
        let reference = key == "value" && path.contains("entries") || key == "[]" && path.dropLast().last == "receiverThreadIds"
        let flag = key == "[]" && path.dropLast().last == "activeFlags"
        let asyncOption = key == "[]" && path.dropLast().last == "options" && path.contains("questions")
        let request = path.contains("requests") && (["command", "reason", "reviewer", "approvalsReviewer"].contains(key)
            || key == "[]" && path.dropLast().last == "availableDecisions")
        let allowed = !redacted && (metadata.contains(key) || question || text || plan || tool || reference || flag || request || asyncOption || collaboration)
        if let string = value as? String {
            if path.contains("requests"), allowed {
                guard string.utf8.count <= (key == "command" ? 16_000 : 4_000) else { throw AgentHookWireError.invalidMessage }
                return string
            }
            return allowed ? String(string.prefix(text ? 8000 : 4000)) : ""
        }
        if value is NSNull { return NSNull() }
        return allowed ? value : NSNull()
    }

    static func patch(_ value: Any, patch: [String: Any]) throws -> Any {
        guard let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation),
              let path = patch["path"] as? [Any], path.count <= 48,
              operation == "remove" || patch["value"] != nil else { throw AgentHookWireError.invalidMessage }
        func apply(_ node: Any, _ depth: Int) throws -> Any {
            if depth == path.count {
                guard operation != "remove", let replacement = patch["value"] else { throw AgentHookWireError.invalidMessage }
                return replacement
            }
            let last = depth + 1 == path.count
            if var object = node as? [String: Any], let key = path[depth] as? String {
                if last {
                    if operation != "add", object[key] == nil { throw AgentHookWireError.invalidMessage }
                    if operation == "remove" { object.removeValue(forKey: key) } else { object[key] = patch["value"] }
                } else {
                    guard let child = object[key] else { throw AgentHookWireError.invalidMessage }
                    object[key] = try apply(child, depth + 1)
                }
                return object
            }
            if var array = node as? [Any], let index = integer(path[depth]), index >= 0, index <= Int64(array.count) {
                let index = Int(index)
                if last {
                    if operation == "add" { array.insert(patch["value"]!, at: index) }
                    else {
                        guard index < array.count else { throw AgentHookWireError.invalidMessage }
                        if operation == "remove" { array.remove(at: index) } else { array[index] = patch["value"]! }
                    }
                } else {
                    guard index < array.count else { throw AgentHookWireError.invalidMessage }
                    array[index] = try apply(array[index], depth + 1)
                }
                return array
            }
            throw AgentHookWireError.invalidMessage
        }
        return try apply(value, 0)
    }

    static func turns(_ state: [String: Any]) -> [[String: Any]]? {
        guard let tail = state["turns"] as? [[String: Any]] else { return nil }
        guard let canonical = state["turnHistory"] as? [String: Any] else { return tail }
        guard canonical["kind"] as? String == "canonical", let history = canonical["history"] as? [String: Any],
              let entities = history["entitiesByKey"] as? [String: [String: Any]],
              let islands = history["islands"] as? [[String: Any]] else { return nil }
        var result: [[String: Any]] = [], seen: Set<String> = []
        for island in islands {
            guard let entries = island["entries"] as? [[String: Any]] else { return nil }
            for entry in entries {
                guard let key = entry["value"] as? String, let turn = entities[key], seen.insert(key).inserted else { return nil }
                result.append(turn)
            }
        }
        return result + tail
    }

    static func snapshot(_ state: [String: Any], thread: String, parent: String?, revision: Int64) -> CodexPrimarySnapshot? {
        guard state["id"] as? String == thread, state["hostId"] as? String == "local",
              state["resumeState"] as? String == "resumed",
              let runtime = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String,
              ["idle", "active"].contains(runtime), let turns = turns(state), turns.count <= 2000,
              let requests = state["requests"] as? [[String: Any]], requests.count <= 64 else { return nil }
        let sourceObject = state["source"] as? [String: Any]
        if let internalSource = sourceObject?["internal"], !(internalSource is NSNull) { return nil }
        let spawnedParent = CodexDesktopExtras.spawnParent(sourceObject)
        if sourceObject?["subAgent"] != nil || sourceObject?["subagent"] != nil {
            guard let spawnedParent, AgentHookEnvelope.validID(spawnedParent) else { return nil }
        }
        let directParent = state["parentThreadId"] as? String
        if let directParent, let spawnedParent, directParent != spawnedParent { return nil }
        let actualParent = directParent ?? spawnedParent
        if let actualParent, (!AgentHookEnvelope.validID(actualParent) || actualParent == thread) { return nil }
        if let parent, actualParent != parent { return nil }
        let source = state["threadSource"] as? String
        guard actualParent != nil || source == "user" else { return nil }
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: thread)
        snapshot.parentThreadID = actualParent
        snapshot.classification = actualParent == nil ? .userSession : .subagent
        snapshot.title = AgentMessagePreview.line(state["title"] as? String) ?? ""
        snapshot.revision = revision
        snapshot.context.cwd = state["cwd"] as? String
        snapshot.context.branch = (state["gitInfo"] as? [String: Any])?["branch"] as? String
        snapshot.context.model = state["latestModel"] as? String
        if let stamp = state["updatedAt"] as? NSNumber, stamp.doubleValue.isFinite {
            let value = stamp.doubleValue
            snapshot.updatedAt = Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        }
        // Do not disable hooks for questions/approvals/children just because
        // those IPC methods or activity links exist. Their full coverage and
        // synchronous policy semantics are different contracts.
        snapshot.capabilities = [.lifecycle, .messages, .tools, .progress]
        guard let turn = turns.last else { snapshot.status = .unknown; snapshot.capabilities = []; return snapshot }
        // Desktop inserts an optimistic local turn with a null ID before its
        // start acknowledgement supplies the real turn ID. This is a known
        // transition, not a revision gap. Keep consuming patches, but expose no
        // turn content or write capability until the owner identifies the turn.
        if turn["turnId"] is NSNull, turn["status"] as? String == "inProgress", runtime == "active",
           let items = turn["items"] as? [[String: Any]], items.isEmpty, requests.isEmpty {
            snapshot.capabilities = []; return snapshot
        }
        guard let turnID = turn["turnId"] as? String, AgentHookEnvelope.validID(turnID),
              let status = turn["status"] as? String, let items = turn["items"] as? [[String: Any]], items.count <= 4000 else { return nil }
        // The owner also publishes idle just before the final turn-status
        // patch. Retain the revision without projecting stale tool/content or
        // accepting an action against this temporarily inconsistent lifecycle.
        if status == "inProgress", runtime == "idle", requests.isEmpty {
            snapshot.capabilities = []; return snapshot
        }
        snapshot.turnID = turnID
        switch status {
        case "inProgress": guard runtime == "active" else { return nil }; snapshot.status = .running
        case "completed": guard runtime == "idle" else { return nil }; snapshot.status = .completed
        case "failed": guard runtime == "idle" else { return nil }; snapshot.status = .failed
        case "interrupted": guard runtime == "idle" else { return nil }; snapshot.status = .cancelled
        default: return nil
        }
        if let stamp = turn["turnStartedAtMs"] as? NSNumber { snapshot.context.startedAt = Date(timeIntervalSince1970: stamp.doubleValue / 1000) }
        var active: (id: String, name: String, detail: String?)?
        var unknownActivity = false
        for item in items {
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "userMessage":
                guard let content = item["content"] as? [[String: Any]] else { return nil }
                let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                snapshot.context.prompt = AgentMessagePreview.userMessage(texts.joined(separator: " "))
                snapshot.context.promptTurnID = turnID
            case "agentMessage":
                if !["commentary", "final_answer"].contains(item["phase"] as? String ?? "") { snapshot.capabilities.remove(.progress) }
                if item["phase"] as? String == "commentary", let text = AgentMessagePreview.line(item["text"] as? String) {
                    snapshot.context.progressText = text
                    snapshot.context.latestActivity = .progress(text)
                }
            case "todo-list":
                guard let plan = item["plan"] as? [[String: Any]], plan.count <= 20 else { return nil }
                var steps: [AgentPlanStep] = []
                for entry in plan {
                    guard let text = AgentMessagePreview.line(entry["step"] as? String),
                          let status = entry["status"] as? String, ["pending", "inProgress", "completed"].contains(status) else { return nil }
                    steps.append(AgentPlanStep(step: String(text.prefix(200)), status: status == "inProgress" ? "in_progress" : status))
                }
                snapshot.context.plan = steps
                snapshot.capabilities.insert(.plans)
            case "webSearch" where item["status"] == nil:
                // Desktop's search/openPage history items have no lifecycle
                // status. They cannot poison unrelated thread observation,
                // but neither presence nor results proves start/completion.
                guard let id = item["id"] as? String, AgentHookEnvelope.validID(id),
                      item["query"] is String, let action = item["action"] as? [String: Any],
                      let actionType = action["type"] as? String, ["search", "openPage"].contains(actionType) else { return nil }
                snapshot.capabilities.remove(.tools)
            case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
                guard let id = item["id"] as? String, AgentHookEnvelope.validID(id), let toolStatus = item["status"] as? String,
                      ["inProgress", "completed", "failed", "declined", "interrupted"].contains(toolStatus) else { return nil }
                let name: String
                let detail: String?
                switch type {
                case "commandExecution": name = "exec_command"; detail = AgentMessagePreview.line(item["command"] as? String)
                case "fileChange": name = "apply_patch"; detail = AgentMessagePreview.line((item["changes"] as? [[String: Any]])?.first?["path"] as? String)
                case "webSearch": name = "web_search"; detail = AgentMessagePreview.line(item["query"] as? String)
                default: name = AgentMessagePreview.line(item["tool"] as? String ?? item["name"] as? String) ?? "Tool"
                    let args = item["arguments"] as? [String: Any]
                    detail = AgentMessagePreview.line(args?["cmd"] as? String ?? args?["path"] as? String ?? args?["pattern"] as? String)
                }
                if toolStatus == "inProgress" { active = (id, name, detail) }
                else {
                    let outcome: AgentToolOutcome = ["failed", "declined"].contains(toolStatus) ? .failed : toolStatus == "interrupted" ? .cancelled : .completed
                    snapshot.context.latestActivity = .completedTool(name: name, detail: detail, outcome: outcome)
                }
            case "reasoning", "functionCallOutput", "steeringUserMessage", "steered", "userInputResponse", "subAgentActivity", "collabAgentToolCall", "contextCompaction": break
            default:
                // A new activity variant may carry tools/plans/questions. No
                // broad observation claims until the shape is understood.
                unknownActivity = true
            }
        }
        if unknownActivity { snapshot.capabilities.subtract([.tools, .messages, .progress, .plans]) }
        if snapshot.status == .running, let active {
            snapshot.activeToolID = active.id; snapshot.activeToolName = active.name
            snapshot.context.toolDetail = active.detail
            snapshot.context.latestActivity = .tool(name: active.name, detail: active.detail)
        }
        for request in requests {
            guard let method = request["method"] as? String, let params = request["params"] as? [String: Any],
                  params["threadId"] as? String == thread, params["turnId"] as? String == turnID else { return nil }
            if method == "item/tool/requestUserInput", let questions = params["questions"] as? [[String: Any]],
               let text = AgentMessagePreview.line(questions.first?["question"] as? String) {
                let id = (request["id"] as? String) ?? integer(request["id"]).map(String.init)
                guard let id else { return nil }
                if let requestID = CodexNativeRequestID(request["id"]),
                   let input = CodexNativeRequests.input(params: params, id: CodexNativeRequests.key(kind: .desktop, thread: thread, turn: turnID, id: requestID)) {
                    if snapshot.context.pendingInput == nil { snapshot.context.pendingInput = input }
                } else if snapshot.context.pendingInput == nil {
                    snapshot.context.pendingInput = AgentPendingInput(id: id, text: text, asynchronous: false)
                }
                snapshot.status = .waitingInput
            } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].contains(method) {
                if (turn["params"] as? [String: Any])?["approvalsReviewer"] as? String == "user",
                   let requestID = CodexNativeRequestID(request["id"]), snapshot.approvals.count < 16 {
                    let key = CodexNativeRequests.key(kind: .desktop, thread: thread, turn: turnID, id: requestID)
                    var approval: AgentApproval?
                    if method == "item/commandExecution/requestApproval" { approval = CodexNativeRequests.approval(params: params, id: key) }
                    else if method == "item/fileChange/requestApproval", let itemID = params["itemId"] as? String,
                            let item = items.first(where: { $0["id"] as? String == itemID && $0["type"] as? String == "fileChange" }),
                            let changes = item["changes"] as? [[String: Any]], let paths = CodexFileApprovalPaths.changes(changes) {
                        approval = CodexNativeRequests.fileApproval(params: params, id: key, paths: paths)
                    }
                    if let approval { snapshot.approvals.append(approval); snapshot.capabilities.insert(.approvals) }
                }
                snapshot.status = .waitingApproval
            } else { return nil }
        }
        if !snapshot.status.isTerminal, snapshot.context.pendingInput == nil, let input = CodexDesktopExtras.asyncInput(items: items) {
            snapshot.context.pendingInput = input; snapshot.status = .waitingInput
        }
        if let flags = (state["threadRuntimeStatus"] as? [String: Any])?["activeFlags"] as? [String] {
            guard flags.allSatisfy({ ["waitingOnUserInput", "waitingOnApproval"].contains($0) }),
                  !flags.contains("waitingOnUserInput") || snapshot.status == .waitingInput,
                  !flags.contains("waitingOnApproval") || snapshot.status == .waitingApproval else { return nil }
        }
        if snapshot.status.isTerminal, requests.isEmpty { snapshot.capabilities.insert(.send) }
        if snapshot.status == .running, snapshot.turnID != nil, requests.isEmpty { snapshot.capabilities.formUnion([.steer, .queue]) }
        if snapshot.status.isTerminal { snapshot.context.latestActivity = nil; snapshot.context.progressText = nil }
        snapshot.observedChildren = CodexDesktopExtras.children(items: items, parent: thread, at: snapshot.updatedAt)
        return snapshot
    }
}

/// All stream parsing and blocking I/O stay off the main actor. The only
/// cross-thread mutable fields are protected by condition. shutdown() wakes a
/// blocked read; condition wakes a reconnect delay or empty-catalog wait.
private final class CodexDesktopStatusWorker: @unchecked Sendable {
    private struct Subscription {
        var state: CodexDesktopStreamState
        var snapshotDeadline: TimeInterval?
        var lastResubscribe: TimeInterval = 0
    }
    private let root: URL
    private let condition = NSCondition()
    private var cancelled = false
    private var roots: Set<String>
    private var descriptor: Int32?
    private let receive: @Sendable (UInt64, CodexPrimaryChannelUpdate) -> Void
    private var deliverySequence: UInt64 = 0
    private var subscriptions: [String: Subscription] = [:]
    private var candidateParents: [String: String] = [:]
    private var nextProbe: [String: TimeInterval] = [:]
    private var client = "initializing-client"
    private var fd: Int32 = -1
    private var lastFrameBytes = 0
    private static let maximumThreads = 32

    init(root: URL, threads: Set<String>, receive: @escaping @Sendable (UInt64, CodexPrimaryChannelUpdate) -> Void) {
        self.root = root; roots = Self.bounded(threads); self.receive = receive
    }

    private static func bounded(_ threads: Set<String>) -> Set<String> {
        Set(threads.filter { UUID(uuidString: $0) != nil }.sorted().prefix(maximumThreads))
    }
    func start() { DispatchQueue(label: "app.notchx.agent.desktop-status", qos: .utility).async { self.run() } }
    func updateThreads(_ threads: Set<String>) {
        condition.lock(); roots = Self.bounded(threads); condition.broadcast(); condition.unlock()
    }
    func cancel() {
        condition.lock(); cancelled = true
        if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
        condition.broadcast(); condition.unlock()
    }
    private var stopped: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    private var requested: Set<String> { condition.lock(); defer { condition.unlock() }; return roots }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func emit(_ update: CodexPrimaryChannelUpdate) {
        deliverySequence &+= 1
        receive(deliverySequence, update)
    }

    private func run() {
        var delay: TimeInterval = 0.25
        while !stopped {
            condition.lock()
            while roots.isEmpty && !cancelled { condition.wait() }
            condition.unlock()
            if stopped { break }
            do {
                try connect()
                let initialized = try request("initialize", version: 0, params: ["clientType": "notchx"])
                guard let id = CodexDesktopWire.clientID(initialized) else { throw AgentHookWireError.invalidMessage }
                client = id
                let connectedAt = now
                while !stopped, !requested.isEmpty {
                    try reconcile()
                    var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&entry, 1, 250)
                    if ready < 0, errno == EINTR { continue }
                    guard ready >= 0 else { throw AgentHookWireError.unavailable }
                    if ready > 0 { try autoreleasepool { try handle(readMessage(until: now + 3)) } }
                    if now - connectedAt > 15 { delay = 0.25 }
                }
            } catch { /* Existing router unavailable/changed: revoke, never create one. */ }
            disconnect()
            if stopped { break }
            condition.lock()
            if !cancelled, !roots.isEmpty { _ = condition.wait(until: Date().addingTimeInterval(delay)) }
            condition.unlock()
            delay = min(delay * 2, 15)
        }
        disconnect()
    }

    private func connect() throws {
        let path = root.appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard AgentUnixSocket.ownedSocket(path), lstat(root.appendingPathComponent("ipc").path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw AgentHookWireError.unsafePath }
        fd = try AgentUnixSocket.descriptor()
        condition.lock(); descriptor = fd; let wasCancelled = cancelled; condition.unlock()
        guard !wasCancelled else { throw AgentHookWireError.unavailable }
        var address = try AgentUnixSocket.address(path)
        let connected = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw AgentHookWireError.unavailable }
            try AgentUnixSocket.wait(fd, events: Int16(POLLOUT), until: now + 2)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw AgentHookWireError.unavailable }
        }
        var peer: uid_t = 0, group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else { throw AgentHookWireError.unsafePath }
        client = "initializing-client"
    }

    private func disconnect() {
        condition.lock(); descriptor = nil; condition.unlock()
        if fd >= 0 { close(fd); fd = -1 }
        let removed = Set(subscriptions.keys)
        subscriptions.removeAll(); candidateParents.removeAll(); nextProbe.removeAll()
        if !removed.isEmpty, !stopped { emit(.unavailable(.desktop, removed)) }
    }

    private func reconcile() throws {
        let roots = requested
        // A child is reachable only through a live requested root/ancestor.
        var desired = roots
        for _ in 0..<8 {
            let more = Set(candidateParents.compactMap { desired.contains($0.value) ? $0.key : nil })
            let next = desired.union(more)
            if next == desired { break }; desired = next
        }
        desired = Set(desired.sorted { roots.contains($0) && !roots.contains($1) || roots.contains($0) == roots.contains($1) && $0 < $1 }.prefix(Self.maximumThreads))
        for thread in Set(subscriptions.keys).subtracting(desired) { try unfollow(thread); withdraw(thread) }
        candidateParents = candidateParents.filter { desired.contains($0.key) && desired.contains($0.value) }
        nextProbe = nextProbe.filter { desired.contains($0.key) }
        for (thread, entry) in subscriptions {
            if let deadline = entry.snapshotDeadline, now > deadline { try unfollow(thread); withdraw(thread); nextProbe[thread] = now + 15 }
        }
        var budget = 4
        for thread in desired.sorted() where subscriptions[thread] == nil && now >= (nextProbe[thread] ?? 0) {
            guard budget > 0, !stopped else { break }; budget -= 1
            nextProbe[thread] = now + 30
            let response = try request("thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": thread])
            guard let owner = CodexDesktopWire.ownerID(response) else { continue }
            let settings = try request("thread-follower-read-model-settings", version: 1, params: ["conversationId": thread], target: owner)
            guard CodexDesktopWire.validSettings(settings, owner: owner), requested.contains(thread) || candidateParents[thread] != nil else { continue }
            let parent = roots.contains(thread) ? nil : candidateParents[thread]
            subscriptions[thread] = Subscription(state: CodexDesktopStreamState(thread: thread, owner: owner, expectedParent: parent), snapshotDeadline: now + 3)
            try follow(thread: thread, owner: owner, following: true)
        }
    }

    private func withdraw(_ thread: String) {
        // A disconnected parent must not leave stale descendant coverage.
        var removed: Set<String> = [thread]
        for _ in 0..<8 {
            let next = removed.union(candidateParents.compactMap { removed.contains($0.value) ? $0.key : nil })
            if next == removed { break }; removed = next
        }
        for id in removed { subscriptions.removeValue(forKey: id) }
        emit(.unavailable(.desktop, removed))
    }
    private func unfollow(_ thread: String) throws {
        if let entry = subscriptions[thread] { try follow(thread: thread, owner: entry.state.owner, following: false) }
    }
    private func follow(thread: String, owner: String, following: Bool) throws {
        try write(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "sourceClientId": client, "targetClientIds": [owner],
            "params": ["conversationId": thread, "hostId": "local", "following": following]])
    }

    private func handle(_ message: [String: Any]) throws {
        guard message["type"] as? String == "broadcast", let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        if method == "ipc-connection-reset" { throw AgentHookWireError.unavailable }
        if method == "client-status-changed", let id = params["clientId"] as? String {
            if params["status"] as? String == "disconnected" {
                for thread in subscriptions.keys.filter({ subscriptions[$0]?.state.owner == id }) { withdraw(thread); nextProbe[thread] = now + 1 }
            } else if params["status"] as? String == "connected" {
                for thread in nextProbe.keys { nextProbe[thread] = min(nextProbe[thread] ?? now, now + 1) }
            }
            return
        }
        guard let thread = params["conversationId"] as? String, var entry = subscriptions[thread] else { return }
        switch entry.state.consume(message) {
        case .ignored: return
        case .resubscribe:
            emit(.unavailable(.desktop, [thread]))
            // One bounded snapshot recovery; repeated mismatch/unknown shapes
            // lose this subscription instead of creating a resend loop.
            guard now - entry.lastResubscribe >= 5 else {
                try unfollow(thread); withdraw(thread); nextProbe[thread] = now + 30; return
            }
            entry.lastResubscribe = now; entry.snapshotDeadline = now + 3
            subscriptions[thread] = entry
            try follow(thread: thread, owner: entry.state.owner, following: true)
        case .snapshot(let snapshot):
            entry.snapshotDeadline = nil; subscriptions[thread] = entry
            // Also bound retained tree sizes across multiple followed roots.
            let bytes = subscriptions.values.reduce(0) { $0 + $1.state.retainedBytes }
            guard bytes <= 16 * 1024 * 1024 else { throw AgentHookWireError.invalidMessage }
            for child in entry.state.childCandidates where subscriptions.count + candidateParents.count < Self.maximumThreads {
                if !requested.contains(child), candidateParents[child] == nil { candidateParents[child] = thread }
            }
            emit(.snapshot(snapshot))
        }
    }

    private func request(_ method: String, version: Int, params: [String: Any], target: String? = nil) throws -> [String: Any] {
        let id = UUID().uuidString, deadline = now + 2
        var object: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": client,
            "method": method, "version": version, "params": params, "timeoutMs": 1500]
        if let target { object["targetClientId"] = target }
        try write(object)
        var budget = 64 * 1024 * 1024
        for _ in 0..<128 {
            let message = try readMessage(until: deadline)
            budget -= lastFrameBytes
            guard budget >= 0 else { throw AgentHookWireError.invalidMessage }
            if message["type"] as? String == "response", message["requestId"] as? String == id {
                guard message["method"] as? String == method || message["resultType"] as? String == "error" else { throw AgentHookWireError.invalidMessage }
                return message
            }
            try handle(message)
        }
        throw AgentHookWireError.invalidMessage
    }
    private func write(_ message: [String: Any]) throws {
        guard !stopped else { throw AgentHookWireError.unavailable }
        try AgentUnixSocket.write(CodexDesktopWire.frame(message), to: fd, until: now + 2)
    }
    private func readMessage(until deadline: TimeInterval) throws -> [String: Any] {
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard !stopped else { throw AgentHookWireError.unavailable }
                try AgentUnixSocket.wait(fd, events: Int16(POLLIN), until: deadline)
                var buffer = [UInt8](repeating: 0, count: min(8192, count - data.count))
                let size = Darwin.read(fd, &buffer, buffer.count)
                if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard size > 0 else { throw AgentHookWireError.unavailable }
                data.append(contentsOf: buffer.prefix(size))
            }
            return data
        }
        let header = try read(4)
        let length = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        lastFrameBytes = length
        guard CodexDesktopWire.acceptsIncomingFrame(length),
              let object = try JSONSerialization.jsonObject(with: read(length)) as? [String: Any] else { throw AgentHookWireError.invalidMessage }
        return object
    }
}
