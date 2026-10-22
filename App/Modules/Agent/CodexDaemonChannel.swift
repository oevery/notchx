import CoreFoundation
import Foundation

/// Attaches only original UUIDs verified loaded in the existing daemon. Resume
/// can cold-load that same UUID if unload races the check; it never starts/forks
/// a different conversation and sends no history/path/configuration overrides.
@MainActor
final class CodexDaemonChannel: CodexPrimaryChannel {
    let kind = CodexPrimaryChannelKind.daemon
    private let root: URL
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private var threads: Set<String> = []
    private var requestedThreads: Set<String> = []
    private var childParents: [String: String] = [:]
    private var inspectedThreads: Set<String> = []
    private var receive: (@MainActor (CodexPrimaryChannelUpdate) -> Void)?
    private var task: Task<Void, Never>?
    private var connection: CodexDaemonConnection?
    private var generation = UUID()
    private var consecutiveFailures = 0
    private var connectionID: UUID?
    private var states: [String: CodexDaemonEventState] = [:]
    private struct NativeRequest {
        let nativeID: CodexNativeRequestID
        let thread: String
        let turn: String
        let connectionID: UUID
        var input: AgentPendingInput?
        var approval: AgentApproval?
        var fileItemID: String?
        var submitting = false
    }
    private var requests: [String: NativeRequest] = [:]
    private var acknowledged: Set<String> = []
    private var retiredRequests: [String] = []
    private var refreshingToken: UUID?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
         interval: TimeInterval = 1.5, timeout: TimeInterval = 4) {
        self.root = root
        self.interval = max(0.05, interval)
        self.timeout = timeout
    }

    func start(threads: Set<String>, receive: @escaping @MainActor (CodexPrimaryChannelUpdate) -> Void) {
        stop()
        self.threads = Set(threads.filter { UUID(uuidString: $0) != nil }.prefix(80))
        requestedThreads = self.threads
        self.receive = receive
        let token = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                await self.refresh(token: token)
                let delay = self.consecutiveFailures == 0 ? self.interval
                    : min(30, self.interval * pow(2, Double(min(self.consecutiveFailures, 10))))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func updateThreads(_ threads: Set<String>) {
        let requested = Set(threads.filter { UUID(uuidString: $0) != nil }.prefix(80))
        requestedThreads = requested
        var values = requested
        for _ in 0..<8 {
            let children = childParents.filter { values.contains($0.value) }.map { $0.key }
            let expanded = values.union(children)
            if expanded == values { break }
            values = expanded
        }
        childParents = childParents.filter { values.contains($0.key) }
        let removed = self.threads.subtracting(values)
        self.threads = values
        for thread in removed { states.removeValue(forKey: thread); clearRequests(thread); unsubscribe(thread) }
        if !removed.isEmpty { receive?(.unavailable(.daemon, removed)) }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        connection?.cancel(); connection = nil
        connectionID = nil; states.removeAll(); requests.removeAll(); acknowledged.removeAll()
        retiredRequests.removeAll()
        refreshingToken = nil
        childParents.removeAll(); inspectedThreads.removeAll()
        consecutiveFailures = 0
        receive?(.unavailable(.daemon, threads))
        receive = nil
    }

    private func existingConnection() -> CodexDaemonConnection {
        if let connection { return connection }
        let id = UUID(), token = generation
        let connection = CodexDaemonConnection(path: root.appendingPathComponent("app-server-control/app-server-control.sock").path,
            timeout: timeout, events: { [weak self] data in
                self?.ingest(data, connectionID: id, token: token)
            }, disconnected: { [weak self] in
                self?.invalidate(connectionID: id, token: token)
            })
        self.connection = connection
        connectionID = id
        return connection
    }

    private func invalidate(connectionID id: UUID, token: UUID) {
        guard generation == token, connectionID == id else { return }
        let removed = threads
        consecutiveFailures = min(consecutiveFailures + 1, 10)
        connectionID = nil; connection?.cancel(); connection = nil; states.removeAll(); requests.removeAll()
        childParents.removeAll(); inspectedThreads.removeAll(); threads = requestedThreads
        retiredRequests.removeAll()
        receive?(.unavailable(.daemon, removed))
    }

    private func unsubscribe(_ thread: String) {
        guard let connection else { return }
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token, !self.threads.contains(thread) else { return }
            _ = try? await connection.request(method: "thread/unsubscribe", params: ["threadId": thread])
        }
    }

    private func ingest(_ data: Data, connectionID id: UUID, token: UUID) {
        guard generation == token, connectionID == id,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any] else { return }
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String
        guard let thread else { return }
        guard threads.contains(thread) else {
            if object["method"] as? String == "thread/started", let metadata = params["thread"] as? [String: Any],
               let child = Self.childMetadata(metadata), let parent = child.parentThreadID,
               threads.contains(parent), threads.count < 80 {
                childParents[thread] = parent; threads.insert(thread)
                // thread/started automatically attaches this connection. Keep
                // early child events instead of unsubscribing before discovery.
                var childState = CodexDaemonEventState(snapshot: child, turn: nil, directInput: false)
                childState.activate(); states[thread] = childState
                states[parent]?.observeChild(child); publish(parent); publish(thread)
            } else if object["method"] as? String == "thread/started", UUID(uuidString: thread) != nil { unsubscribe(thread) }
            return
        }
        guard var state = states[thread] else { return }
        switch state.ingest(object) {
        case .ignored: return
        case .unavailable:
            states.removeValue(forKey: thread); clearRequests(thread); receive?(.unavailable(.daemon, [thread]))
        case .changed:
            states[thread] = state
            ingestRequest(object, thread: thread, connectionID: id)
            publish(thread)
            if let item = params["item"] as? [String: Any], item["type"] as? String == "collabAgentToolCall",
               item["senderThreadId"] as? String == thread,
               let children = item["receiverThreadIds"] as? [String], !children.isEmpty {
                Task { [weak self] in await self?.observeChildren(children, parent: thread, token: token) }
            }
        }
    }

    private func clearRequests(_ thread: String) {
        requests = requests.filter { $0.value.thread != thread }
    }

    private func publish(_ thread: String) {
        guard var state = states[thread] else { return }
        let pending = requests.sorted { $0.key < $1.key }.filter {
            $0.value.thread == thread && $0.value.turn == state.snapshot.turnID && !state.snapshot.status.isTerminal
        }
        state.setRequests(approvals: pending.compactMap { $0.value.approval }, input: pending.compactMap { $0.value.input }.first)
        states[thread] = state
        if state.subscribed { receive?(.snapshot(state.snapshot)) }
        if let parent = state.snapshot.parentThreadID, states[parent] != nil {
            var child = state.snapshot
            if child.status != .unknown { child.context.lastKnownStatus = child.status }
            states[parent]?.observeChild(child); publish(parent)
        }
    }

    private func ingestRequest(_ object: [String: Any], thread: String, connectionID: UUID) {
        guard let state = states[thread], let params = object["params"] as? [String: Any] else { return }
        requests = requests.filter { $0.value.thread != thread || ($0.value.turn == state.snapshot.turnID && !state.snapshot.status.isTerminal) }
        if object["method"] as? String == "thread/settings/updated",
           (params["threadSettings"] as? [String: Any])?["approvalsReviewer"] as? String != "user" {
            for key in requests.keys where requests[key]?.thread == thread { requests[key]?.approval = nil }
        }
        if object["method"] as? String == "serverRequest/resolved", let id = CodexNativeRequestID(params["requestId"]) {
            for (key, request) in requests where request.thread == thread && request.nativeID == id && request.connectionID == connectionID {
                if request.submitting, acknowledged.count < 64 { acknowledged.insert(key) }
                retiredRequests = Array((retiredRequests + [key]).suffix(512))
                requests.removeValue(forKey: key)
            }
            return
        }
        guard let method = object["method"] as? String,
              ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
              let id = CodexNativeRequestID(object["id"]), let turn = params["turnId"] as? String,
              turn == state.snapshot.turnID, !state.snapshot.status.isTerminal, requests.count < 64 else { return }
        let key = CodexNativeRequests.key(kind: .daemon, thread: thread, turn: turn, id: id) + ":" + connectionID.uuidString
        guard requests[key] == nil, !retiredRequests.contains(key) else { return }
        var request = NativeRequest(nativeID: id, thread: thread, turn: turn, connectionID: connectionID)
        if method == "item/tool/requestUserInput" { request.input = CodexNativeRequests.input(params: params, id: key) }
        else {
            guard params["reviewer"] == nil || params["reviewer"] is NSNull || params["reviewer"] as? String == "user",
                  params["approvalsReviewer"] == nil || params["approvalsReviewer"] is NSNull || params["approvalsReviewer"] as? String == "user" else { return }
            // A native method name does not prove the reviewer is human. Hold
            // a non-actionable handle until this same owner's settings confirm.
            if method == "item/fileChange/requestApproval" { request.fileItemID = params["itemId"] as? String }
            requests[key] = request
            let token = generation
            Task { [weak self] in await self?.enrichApproval(key: key, method: method, params: params, token: token) }
            return
        }
        if request.input != nil || request.approval != nil { requests[key] = request }
    }

    private func humanReviewer(_ request: NativeRequest, connection: CodexDaemonConnection) async -> Bool {
        guard request.connectionID == connectionID, requests.values.contains(where: { $0.nativeID == request.nativeID && $0.thread == request.thread && $0.turn == request.turn }) else { return false }
        guard let resident = try? await loaded(connection), resident.contains(request.thread),
              request.connectionID == connectionID, threads.contains(request.thread),
              let state = states[request.thread], state.snapshot.turnID == request.turn, !state.snapshot.status.isTerminal else { return false }
        // No public atomic only-if-loaded resume exists: an unload after this
        // check can still reload the same UUID, never start a different thread.
        let result = try? await connection.request(method: "thread/resume", params: ["threadId": request.thread, "excludeTurns": true])
        return request.connectionID == connectionID && result?["approvalsReviewer"] as? String == "user"
            && (result?["thread"] as? [String: Any])?["id"] as? String == request.thread
    }

    private func enrichApproval(key: String, method: String, params: [String: Any], token: UUID) async {
        guard let request = requests[key], let itemID = params["itemId"] as? String,
              let connection, request.connectionID == connectionID,
              await humanReviewer(request, connection: connection), generation == token else { return }
        if method == "item/commandExecution/requestApproval" {
            guard var pending = requests[key], let state = states[request.thread], state.snapshot.turnID == request.turn,
                  !state.snapshot.status.isTerminal,
                  let approval = CodexNativeRequests.approval(params: params, id: key) else { return }
            pending.approval = approval; requests[key] = pending; publish(request.thread)
            return
        }
        var paths = await filePaths(request, itemID: itemID, connection: connection)
        // Rollout persistence may trail the request notification slightly.
        // Retry only bounded reads while this exact pending handle is alive.
        for _ in 0..<2 {
            guard paths == nil else { break }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard generation == token, requests[key] != nil, request.connectionID == connectionID else { return }
            paths = await filePaths(request, itemID: itemID, connection: connection)
        }
        guard generation == token, request.connectionID == connectionID, var pending = requests[key],
              let state = states[request.thread], state.snapshot.turnID == request.turn, !state.snapshot.status.isTerminal,
              let paths,
              let approval = CodexNativeRequests.fileApproval(params: params, id: key, paths: paths) else { return }
        pending.approval = approval; requests[key] = pending; publish(request.thread)
    }

    private func filePaths(_ request: NativeRequest, itemID: String, connection: CodexDaemonConnection) async -> [String]? {
        let page = try? await connection.request(method: "thread/turns/list", params: ["threadId": request.thread,
            "limit": 1, "sortDirection": "desc", "itemsView": "full"])
        if let turn = (page?["data"] as? [[String: Any]])?.first, turn["id"] as? String == request.turn,
           let item = (turn["items"] as? [[String: Any]])?.first(where: { $0["id"] as? String == itemID && $0["type"] as? String == "fileChange" }),
           let changes = item["changes"] as? [[String: Any]] {
            return CodexFileApprovalPaths.changes(changes)
        }
        // v2 may omit the pending FileChange until the approval resolves. Do
        // not enable raw events or scan history; use the owner's exact file.
        let result = try? await connection.request(method: "thread/read", params: ["threadId": request.thread, "includeTurns": false])
        guard request.connectionID == connectionID, let metadata = result?["thread"] as? [String: Any],
              metadata["id"] as? String == request.thread, let path = metadata["path"] as? String else { return nil }
        let root = root
        return await Task.detached(priority: .utility) {
            CodexFileApprovalPaths.pending(file: URL(fileURLWithPath: path), root: root,
                thread: request.thread, turn: request.turn, item: itemID)
        }.value
    }

    private func reply(key: String, result: [String: Any]) async -> AgentMessageDelivery {
        guard var request = requests[key], !request.submitting, let connection,
              request.connectionID == connectionID, threads.contains(request.thread), !Task.isCancelled,
              let state = states[request.thread], state.subscribed, state.snapshot.turnID == request.turn,
              !state.snapshot.status.isTerminal else { return .failed }
        let token = generation
        request.submitting = true
        request.approval?.isSubmitting = true
        requests[key] = request; publish(request.thread)
        do { try await connection.respond(id: request.nativeID, result: result) }
        catch {
            if (error as? CodexDaemonConnection.Failure)?.submitted == true { return .uncertain }
            if generation == token, self.connectionID == request.connectionID, var current = requests[key] {
                current.submitting = false; current.approval?.isSubmitting = false
                requests[key] = current; publish(request.thread)
            }
            return .failed
        }
        // Native JSON-RPC responses have no response-of-response. Resolution is
        // the acknowledgement; a successful socket write alone is uncertain.
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if acknowledged.remove(key) != nil { return .accepted }
            guard generation == token, connectionID == request.connectionID, !Task.isCancelled else { return .uncertain }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return .uncertain }
        }
        return .uncertain
    }

    func respondToInput(_ response: AgentInputResponse) async -> AgentMessageDelivery {
        guard let request = requests[response.requestID], let input = request.input,
              response.sessionID == CodexAgentState.id(request.thread), response.turnID == request.turn,
              response.matches(input) else { return .failed }
        return await reply(key: response.requestID, result: ["answers": response.answers.mapValues { ["answers": $0] }])
    }

    func respond(approval: AgentApproval, decision: AgentHookDecision) async -> AgentMessageDelivery {
        guard let request = requests[approval.id], let pending = request.approval,
              pending.sessionID == approval.sessionID, pending.turnID == approval.turnID,
              (decision == .allow && pending.canAllow) || (decision == .deny && pending.canDeny),
              let connection, await humanReviewer(request, connection: connection) else { return .failed }
        if let itemID = request.fileItemID {
            guard let paths = await filePaths(request, itemID: itemID, connection: connection),
                  paths.joined(separator: "\n") == pending.command else { return .failed }
        }
        return await reply(key: approval.id, result: ["decision": decision == .allow ? "accept" : (pending.denyEndsTurn ? "cancel" : "decline")])
    }

    private func loaded(_ connection: CodexDaemonConnection) async throws -> Set<String> {
        var ids: Set<String> = [], cursor: String?
        for _ in 0..<4 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await connection.request(method: "thread/loaded/list", params: params)
            guard let data = result["data"] as? [String] else { throw CodexDaemonConnection.Failure(submitted: false, code: nil) }
            ids.formUnion(data.filter { UUID(uuidString: $0) != nil })
            guard let next = result["nextCursor"] as? String, next != cursor else { break }
            cursor = next
        }
        return ids
    }

    private func snapshot(_ thread: String, connection: CodexDaemonConnection) async throws -> (CodexPrimarySnapshot, [String: Any]?)? {
        let metadata = try await connection.request(method: "thread/read", params: ["threadId": thread, "includeTurns": false])
        guard let object = metadata["thread"] as? [String: Any], object["id"] as? String == thread,
              let status = object["status"] as? [String: Any],
              ["active", "idle", "systemError"].contains(status["type"] as? String ?? "") else { return nil }
        // Read one page only. Never full-history hydrate/resume to observe a turn.
        let page: [String: Any]
        do {
            page = try await connection.request(method: "thread/turns/list", params: [
                "threadId": thread, "limit": 1, "sortDirection": "desc", "itemsView": "full"])
        } catch let failure as CodexDaemonConnection.Failure where failure.unmaterializedThread == thread {
            // Do not manufacture history or interrupt other subscriptions
            // while this new conversation waits for its first user message.
            return nil
        }
        guard let turns = page["data"] as? [[String: Any]] else { return nil }
        // The metadata can race unload; revalidate residency before publishing.
        guard try await loaded(connection).contains(thread) else { return nil }
        guard let snapshot = Self.normalize(thread: object, turn: turns.first) else { return nil }
        if snapshot.classification == .subagent, let parent = snapshot.parentThreadID, parent != thread, threads.contains(parent) {
            childParents[thread] = parent
        }
        guard allowed(snapshot) else { return nil }
        return (snapshot, turns.first)
    }

    private func allowed(_ snapshot: CodexPrimarySnapshot) -> Bool {
        if snapshot.classification == .userSession { return snapshot.parentThreadID == nil && requestedThreads.contains(snapshot.threadID) }
        guard snapshot.classification == .subagent, let parent = snapshot.parentThreadID else { return false }
        return parent != snapshot.threadID && threads.contains(parent) && childParents[snapshot.threadID] == parent
    }

    private func discoverChildren(_ resident: Set<String>, connection: CodexDaemonConnection, token: UUID) async throws {
        // Metadata only, once per resident identity/connection. Unknown roots
        // are never resumed. Multi-level children are admitted parent first.
        var candidates: [String: CodexPrimarySnapshot] = [:]
        for id in resident.subtracting(threads).subtracting(inspectedThreads).sorted().prefix(80) {
            guard generation == token, !Task.isCancelled else { return }
            let result = try await connection.request(method: "thread/read", params: ["threadId": id, "includeTurns": false])
            guard generation == token else { return }
            inspectedThreads.insert(id)
            if let metadata = result["thread"] as? [String: Any], metadata["id"] as? String == id,
               let snapshot = Self.childMetadata(metadata) {
                candidates[id] = snapshot
            }
        }
        for _ in 0..<8 {
            var added = false
            for (id, snapshot) in candidates where threads.count < 80 {
                guard let parent = snapshot.parentThreadID, parent != id, threads.contains(parent) else { continue }
                childParents[id] = parent; threads.insert(id); candidates.removeValue(forKey: id); added = true
                states[parent]?.observeChild(snapshot); publish(parent)
            }
            if !added { break }
        }
        // Revisit orphan metadata if its parent becomes visible on a later pass.
        inspectedThreads.subtract(candidates.keys)
        inspectedThreads.formIntersection(resident)
    }

    private func observeChildren(_ ids: [String], parent: String, token: UUID) async {
        guard generation == token, threads.contains(parent), let connection, let identity = connectionID else { return }
        for id in Set(ids.filter { UUID(uuidString: $0) != nil && $0 != parent }).sorted().prefix(32) {
            let result = try? await connection.request(method: "thread/read", params: ["threadId": id, "includeTurns": false])
            guard generation == token, connectionID == identity, threads.contains(parent) else { return }
            guard let metadata = result?["thread"] as? [String: Any], metadata["id"] as? String == id,
                  let child = Self.childMetadata(metadata), child.parentThreadID == parent else { continue }
            states[parent]?.observeChild(child); publish(parent)
        }
        await refresh(token: token)
    }

    static func childMetadata(_ metadata: [String: Any]) -> CodexPrimarySnapshot? {
        guard let parent = metadata["parentThreadId"] as? String, UUID(uuidString: parent) != nil,
              parent != metadata["id"] as? String else { return nil }
        if let source = metadata["source"] as? [String: Any] {
            guard CodexDesktopExtras.spawnParent(source) == parent else { return nil }
        }
        var display = metadata
        if (metadata["status"] as? [String: Any])?["type"] as? String == "notLoaded" { display["status"] = ["type": "idle"] }
        guard var child = normalize(thread: display, turn: nil) else { return nil }
        child.status = .unknown
        child.title = AgentMessagePreview.line(metadata["agentNickname"] as? String ?? metadata["name"] as? String) ?? String(child.threadID.prefix(8))
        return child
    }

    private func attach(_ thread: String, connection: CodexDaemonConnection, token: UUID) async throws {
        guard let (initial, initialTurn) = try await snapshot(thread, connection: connection),
              generation == token, threads.contains(thread) else { return }
        // Recheck immediately before the only resume. Public RPC has no atomic
        // only-if-loaded precondition; a same-UUID cold reload remains possible.
        // Detect the optional API before subscribing. An optional RPC must not
        // sit in front of newly delivered questions on an active subscription.
        let queue = initial.classification == .userSession
            ? try? await connection.request(method: "thread/queue/list", params: ["threadId": thread, "limit": 1]) : nil
        guard try await loaded(connection).contains(thread), generation == token, threads.contains(thread) else { return }
        states[thread] = CodexDaemonEventState(snapshot: initial, turn: initialTurn, directInput: false)
        let result = try await connection.request(method: "thread/resume", params: ["threadId": thread, "excludeTurns": true], mutation: true)
        guard generation == token, threads.contains(thread),
              let metadata = result["thread"] as? [String: Any], metadata["id"] as? String == thread,
              let verified = Self.normalize(thread: metadata, turn: nil), allowed(verified) else { throw CodexDaemonConnection.Failure(submitted: true, code: nil) }
        await connection.eventBarrier()
        let count = states[thread]?.eventCount ?? 0
        guard let (fresh, turn) = try await snapshot(thread, connection: connection) else { throw CodexDaemonConnection.Failure(submitted: true, code: nil) }
        await connection.eventBarrier()
        guard generation == token, threads.contains(thread), var state = states[thread] else { return }
        state.rebase(fresh, turn: turn, eventsBeforeRead: count)
        states[thread] = state
        state.activate(directInput: metadata["canAcceptDirectInput"] as? Bool == true && state.snapshot.classification == .userSession)
        state.setQueueAvailable(queue?["data"] is [Any])
        states[thread] = state
        publish(thread)
    }

    private func refresh(token: UUID) async {
        guard generation == token, !threads.isEmpty, refreshingToken != token else { return }
        refreshingToken = token
        defer { if refreshingToken == token { refreshingToken = nil } }
        let connection = existingConnection()
        let id = connectionID
        do {
            let resident = try await loaded(connection)
            guard generation == token, !Task.isCancelled else { return }
            try await discoverChildren(resident, connection: connection, token: token)
            let watched = threads
            let absent = watched.subtracting(resident)
            for thread in absent { states.removeValue(forKey: thread); clearRequests(thread) }
            if !absent.isEmpty { receive?(.unavailable(.daemon, absent)) }
            for thread in watched.intersection(resident).sorted() {
                guard generation == token, !Task.isCancelled else { return }
                if states[thread]?.subscribed != true { try await attach(thread, connection: connection, token: token) }
            }
            if generation == token { consecutiveFailures = 0 }
        } catch {
            if let id { invalidate(connectionID: id, token: token) }
        }
    }

    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery {
        guard task != nil, threads.contains(request.sessionID.sessionID),
              request.sessionID.providerID == CodexAgentState.id(request.sessionID.sessionID).providerID,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= 32_000 else { return .failed }
        let token = generation, connection = existingConnection(), thread = request.sessionID.sessionID
        do {
            guard try await loaded(connection).contains(thread),
                  let state = states[thread], state.subscribed,
                  generation == token, !Task.isCancelled, threads.contains(thread) else { return .failed }
            let current = state.snapshot
            let params: [String: Any]
            let method: String
            switch request.mode {
            case .send:
                guard current.capabilities.contains(.send), current.turnID == request.turnID else { return .failed }
                method = "turn/start"
                params = ["threadId": thread, "clientUserMessageId": request.id.uuidString,
                          "input": [["type": "text", "text": request.text]]]
            case .steer:
                guard current.capabilities.contains(.steer), let turn = request.turnID, current.turnID == turn else { return .failed }
                method = "turn/steer"
                params = ["threadId": thread, "expectedTurnId": turn, "clientUserMessageId": request.id.uuidString,
                          "input": [["type": "text", "text": request.text]]]
            case .queue:
                guard current.capabilities.contains(.queue), current.turnID == request.turnID else { return .failed }
                method = "thread/queue/add"
                params = ["threadId": thread, "clientUserMessageId": request.id.uuidString,
                          "input": [["type": "text", "text": request.text]]]
            }
            let result = try await connection.request(method: method, params: params, mutation: true)
            // A disconnect after submission is unknown, not a retry invitation.
            guard generation == token, !Task.isCancelled else { return .uncertain }
            if request.mode == .steer { return result["turnId"] as? String == request.turnID ? .accepted : .uncertain }
            if request.mode == .queue {
                guard let queued = result["queuedSubmission"] as? [String: Any],
                      let id = queued["id"] as? String, !id.isEmpty,
                      queued["clientUserMessageId"] as? String == request.id.uuidString else { return .uncertain }
                return .accepted
            }
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else { return .uncertain }
            return .accepted
        } catch {
            if let id = connectionID, self.connection === connection { invalidate(connectionID: id, token: token) }
            return (error as? CodexDaemonConnection.Failure)?.submitted == true ? .uncertain : .failed
        }
    }

    static func normalize(thread: [String: Any], turn: [String: Any]?) -> CodexPrimarySnapshot? {
        guard let id = thread["id"] as? String, UUID(uuidString: id) != nil,
              let runtime = thread["status"] as? [String: Any], let runtimeType = runtime["type"] as? String,
              ["active", "idle", "systemError"].contains(runtimeType) else { return nil }
        var value = CodexPrimarySnapshot(kind: .daemon, threadID: id)
        value.turnID = turn?["id"] as? String
        value.parentThreadID = thread["parentThreadId"] as? String
        if let source = thread["source"] as? [String: Any],
           value.parentThreadID == nil || CodexDesktopExtras.spawnParent(source) != value.parentThreadID { return nil }
        let source = thread["source"] as? String
        if value.parentThreadID != nil { value.classification = .subagent }
        else if ["cli", "vscode", "exec", "appServer"].contains(source ?? "") { value.classification = .userSession }
        value.title = AgentMessagePreview.line(thread["name"] as? String) ?? ""
        value.context.cwd = thread["cwd"] as? String
        value.context.model = thread["model"] as? String
        value.context.branch = (thread["gitInfo"] as? [String: Any])?["branch"] as? String
        value.updatedAt = Self.timestamp(thread["updatedAt"])
        // Turn.startedAt is an optional upstream Unix timestamp in seconds.
        // Never replace it with poll arrival time or the thread's updatedAt.
        value.context.startedAt = Self.timestamp(turn?["startedAt"])
        let flags = runtime["activeFlags"] as? [String] ?? []
        let status = turn?["status"] as? String
        if flags.contains("waitingOnApproval") { value.status = .waitingApproval }
        else if flags.contains("waitingOnUserInput") { value.status = .waitingInput }
        else if runtimeType == "systemError" || status == "failed" { value.status = .failed }
        else if runtimeType == "active" { value.status = .running }
        else if status == "interrupted" { value.status = .cancelled }
        else if status == "completed" { value.status = .completed }
        let items = Array((turn?["items"] as? [[String: Any]] ?? []).suffix(200))
        for item in items {
            let type = item["type"] as? String ?? ""
            if type == "userMessage", let content = item["content"] as? [[String: Any]] {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
                value.context.prompt = AgentMessagePreview.userMessage(text)
                value.context.promptTurnID = value.turnID
            } else if type == "agentMessage", item["phase"] as? String == "commentary" {
                value.context.progressText = AgentMessagePreview.line(item["text"] as? String)
                if let text = value.context.progressText { value.context.latestActivity = .progress(text) }
            } else if let name = toolName(type: type, item: item) {
                let detail: String?
                switch type {
                case "commandExecution": detail = AgentMessagePreview.line(item["command"] as? String)
                case "fileChange": detail = AgentMessagePreview.line((item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String }.joined(separator: ", "))
                case "webSearch": detail = AgentMessagePreview.line(item["query"] as? String)
                default: detail = nil
                }
                if item["status"] as? String == "inProgress" {
                    value.activeToolName = name; value.activeToolID = item["id"] as? String
                    value.context.toolDetail = detail
                    value.context.latestActivity = .tool(name: name, detail: detail)
                } else if let date = value.updatedAt {
                    let outcome: AgentToolOutcome = item["status"] as? String == "failed" ? .failed : .completed
                    value.context.lastCompletedTool = AgentCompletedTool(name: name, detail: detail, finishedAt: date, outcome: outcome)
                    value.context.latestActivity = .completedTool(name: name, detail: detail, outcome: outcome)
                }
            }
            // reasoning, command output, diffs, tool arguments/results and raw
            // request_user_input payloads deliberately do not enter the snapshot.
        }
        if value.status != .running { value.activeToolName = nil; value.activeToolID = nil }
        if thread["canAcceptDirectInput"] as? Bool == true, value.classification == .userSession, flags.isEmpty {
            if runtimeType == "idle", value.status.isTerminal { value.capabilities.insert(.send) }
            if runtimeType == "active", value.status == .running, value.turnID != nil { value.capabilities.insert(.steer) }
        }
        // No lifecycle/tools/messages/questions/approvals capability is claimed:
        // these are sampled snapshots without an authoritative subscription.
        return value
    }

    static func timestamp(_ value: Any?) -> Date? {
        // Native Int/Double and JSON numbers bridge to NSNumber. CFBoolean
        // bridges too, but is never an upstream numeric timestamp.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    static func toolName(type: String, item: [String: Any]) -> String? {
        switch type {
        case "commandExecution": return "exec_command"
        case "fileChange": return "apply_patch"
        case "webSearch": return "web_search"
        case "mcpToolCall", "dynamicToolCall": return item["tool"] as? String
        default: return nil
        }
    }
}
