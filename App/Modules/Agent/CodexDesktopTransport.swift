import Darwin
import Foundation

/// Compatibility adapter for the probed Desktop protocol, not the public
/// app-server protocol. Only talks to an existing, same-user Desktop router.
/// No router creation, thread resume, configuration changes or automatic retry.
enum CodexDesktopTransport {
    static func respond(approval: AgentApproval, decision: AgentHookDecision, owner: String, root: URL) async -> AgentMessageDelivery {
        guard decision == .allow && approval.canAllow || decision == .deny && approval.canDeny else { return .failed }
        return await invoke(root: root, owner: owner, action: .approval(approval, decision))
    }
    static func respondToInput(_ response: AgentInputResponse, input: AgentPendingInput, owner: String, root: URL) async -> AgentMessageDelivery {
        guard response.matches(input) else { return .failed }
        return await invoke(root: root, owner: owner, action: .input(response, input))
    }

    static func send(_ request: AgentMessageRequest, root: URL, owner: String) async -> AgentMessageDelivery {
        guard request.sessionID == CodexAgentState.id(request.sessionID.sessionID), UUID(uuidString: request.sessionID.sessionID) != nil,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= 32_000, !Task.isCancelled else { return .failed }
        return await invoke(root: root, owner: owner, action: .message(request))
    }

    private static func invoke(root: URL, owner: String, action: CodexDesktopAction) async -> AgentMessageDelivery {
        guard AgentHookEnvelope.validID(owner), !Task.isCancelled else { return .failed }
        let invocation = CodexDesktopInvocation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: invocation.run(root: root, owner: owner, action: action))
                }
            }
        } onCancel: { invocation.cancel() }
    }
}

private enum CodexDesktopAction: Sendable {
    case message(AgentMessageRequest)
    case input(AgentInputResponse, AgentPendingInput)
    case approval(AgentApproval, AgentHookDecision)

    var thread: String {
        switch self {
        case .message(let request): return request.sessionID.sessionID
        case .input(let response, _): return response.sessionID.sessionID
        case .approval(let approval, _): return approval.sessionID.sessionID
        }
    }
}

private final class CodexDesktopInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var descriptor: Int32?
    private var submitted = false
    private var clientID = "initializing-client"
    private var receivedBytes = 0
    private var deadline: TimeInterval = 0
    private var queueConfirmation: (thread: String, owner: String, id: String)?
    private var queueObserved = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
    }

    func run(root: URL, owner: String, action: CodexDesktopAction) -> AgentMessageDelivery {
        var fd: Int32 = -1
        defer {
            lock.lock(); descriptor = nil; lock.unlock()
            if fd >= 0 { close(fd) }
        }
        do {
            let path = root.appendingPathComponent("ipc/ipc.sock").path
            var directory = stat()
            let parent = root.appendingPathComponent("ipc").path
            guard AgentUnixSocket.ownedSocket(path), lstat(parent, &directory) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
                  directory.st_mode & 0o022 == 0 else { return .failed }
            fd = try AgentUnixSocket.descriptor()
            lock.lock(); descriptor = fd; let stopped = cancelled; lock.unlock()
            guard !stopped else { return .failed }
            deadline = ProcessInfo.processInfo.systemUptime + 15
            var address = try AgentUnixSocket.address(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { return .failed }
                try AgentUnixSocket.wait(fd, events: Int16(POLLOUT), until: deadline)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return .failed }
            }
            var peer: uid_t = 0, group: gid_t = 0
            guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else { return .failed }
            let initialized = try exchange(fd, method: "initialize", version: 0, params: ["clientType": "notchx"])
            guard let id = CodexDesktopWire.clientID(initialized) else { return .failed }
            clientID = id
            let thread = action.thread
            let discovery = try exchange(fd, method: "thread-owner-discovery", version: 1,
                                     params: ["hostId": "local", "conversationId": thread])
            guard CodexDesktopWire.ownerID(discovery) == owner else { return .failed }
            // An unloaded thread has no owner: fail rather than acquiring it in
            // another app-server or delivering to a recent/different thread.
            let settings = try exchange(fd, method: "thread-follower-read-model-settings", version: 1,
                                        params: ["conversationId": thread], target: owner)
            guard CodexDesktopWire.validSettings(settings, owner: owner) else { return .failed }
            defer { try? follow(fd, thread: thread, owner: owner, following: false) }
            let fresh = try freshSnapshot(descriptor: fd, thread: thread, owner: owner)
            return try perform(action, fresh: fresh, descriptor: fd, root: root, owner: owner)
        } catch { return submitted ? .uncertain : .failed }
    }

    private func perform(_ action: CodexDesktopAction, fresh: CodexPrimarySnapshot,
                         descriptor fd: Int32, root: URL, owner: String) throws -> AgentMessageDelivery {
        let thread = action.thread
        switch action {
        case .message(let request):
            guard fresh.classification == .userSession, fresh.capabilities.contains(request.mode.capability),
                  fresh.turnID == request.turnID else { return .failed }
            switch request.mode {
            case .send:
                let response = try exchange(fd, method: "thread-follower-start-turn", version: 2,
                    params: CodexDesktopWire.sendParams(request), target: owner, mutation: true)
                return CodexDesktopWire.delivery(response, owner: owner)
            case .steer:
                // Desktop intentionally steers its latest active turn. Its
                // follower wrapper has no strict expectedTurnId precondition.
                let response = try exchange(fd, method: "thread-follower-steer-turn", version: 1,
                    params: ["conversationId": thread, "clientUserMessageId": request.id.uuidString,
                        "input": [["type": "text", "text": request.text, "text_elements": []]],
                        "restoreMessage": CodexDesktopWire.restoreMessage(request)], target: owner, mutation: true)
                guard response["handledByClientId"] as? String == owner,
                      let result = (response["result"] as? [String: Any])?["result"] as? [String: Any],
                      let turn = result["turnId"] as? String, !turn.isEmpty else { return .uncertain }
                return .accepted
            case .queue:
                let old = try CodexDesktopQueue.read(root: root, thread: thread)
                guard !old.contains(where: { $0["id"] as? String == request.id.uuidString }) else { return .uncertain }
                queueConfirmation = (thread, owner, request.id.uuidString)
                let response = try exchange(fd, method: "thread-follower-set-queued-follow-ups-state", version: 1,
                    params: ["conversationId": thread, "state": [thread: old + [CodexDesktopWire.restoreMessage(request)]],
                        "discardedMessageIds": []], target: owner, mutation: true)
                guard nativeDelivery(response, owner: owner) == .accepted else { return .uncertain }
                return try confirmQueue(request, root: root, descriptor: fd)
            }
        case .input(let response, let reviewed):
            guard fresh.turnID == response.turnID, fresh.context.pendingInput == reviewed, response.matches(reviewed),
                  let requestID = CodexNativeRequests.requestID(key: response.requestID, kind: .desktop, thread: thread, turn: response.turnID) else { return .failed }
            let reply = try exchange(fd, method: "thread-follower-submit-user-input", version: 1, params: [
                "conversationId": thread, "requestId": requestID.wireValue,
                "response": ["answers": response.answers.mapValues { ["answers": $0] }]], target: owner, mutation: true)
            return nativeDelivery(reply, owner: owner)
        case .approval(let reviewed, let decision):
            guard fresh.turnID == reviewed.turnID,
                  let current = fresh.approvals.first(where: { $0.id == reviewed.id }),
                  current.command == reviewed.command, current.reason == reviewed.reason, current.tool == reviewed.tool,
                  current.canAllow == reviewed.canAllow, current.canDeny == reviewed.canDeny, current.denyEndsTurn == reviewed.denyEndsTurn,
                  let requestID = CodexNativeRequests.requestID(key: reviewed.id, kind: .desktop, thread: thread, turn: reviewed.turnID),
                  decision == .allow && current.canAllow || decision == .deny && current.canDeny else { return .failed }
            let method = current.tool == "apply_patch" ? "thread-follower-file-approval-decision" : "thread-follower-command-approval-decision"
            let reply = try exchange(fd, method: method, version: 1, params: [
                "conversationId": thread, "requestId": requestID.wireValue,
                "decision": decision == .allow ? "accept" : current.denyEndsTurn ? "cancel" : "decline"], target: owner, mutation: true)
            return nativeDelivery(reply, owner: owner)
        }
    }

    private func follow(_ fd: Int32, thread: String, owner: String, following: Bool) throws {
        try AgentUnixSocket.write(CodexDesktopWire.frame(["type": "broadcast", "method": "thread-stream-following-changed",
            "version": 1, "sourceClientId": clientID, "targetClientIds": [owner],
            "params": ["conversationId": thread, "hostId": "local", "following": following]]), to: fd, until: deadline)
    }

    private func freshSnapshot(descriptor fd: Int32, thread: String, owner: String) throws -> CodexPrimarySnapshot {
        try follow(fd, thread: thread, owner: owner, following: true)
        var stream = CodexDesktopStreamState(thread: thread, owner: owner)
        while true {
            switch stream.consume(try readMessage(fd)) {
            case .snapshot(let value): return value
            case .resubscribe: throw AgentHookWireError.unavailable
            case .ignored: continue
            }
        }
    }

    private func confirmQueue(_ request: AgentMessageRequest, root: URL, descriptor fd: Int32) throws -> AgentMessageDelivery {
        if queueObserved { return .accepted }
        if let stored = try? CodexDesktopQueue.read(root: root, thread: request.sessionID.sessionID),
           stored.contains(where: { $0["id"] as? String == request.id.uuidString && $0["text"] as? String == request.text }) { return .accepted }
        // A queued entry can be consumed before file readback. The original
        // owner's correlated push is independent confirmation, even after ACK.
        // Bound the extra wait; never resend when neither proof arrives.
        let previous = deadline
        deadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1)
        defer { deadline = previous }
        while !queueObserved { _ = try readMessage(fd) }
        return .accepted
    }

    private func nativeDelivery(_ reply: [String: Any], owner: String) -> AgentMessageDelivery {
        guard reply["handledByClientId"] as? String == owner,
              let result = reply["result"] as? [String: Any], result["ok"] as? Bool == true else { return .uncertain }
        return .accepted
    }

    private func readMessage(_ fd: Int32) throws -> [String: Any] {
        let header = try read(4, from: fd)
        let count = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard CodexDesktopWire.acceptsIncomingFrame(count),
              let reply = try JSONSerialization.jsonObject(with: read(count, from: fd)) as? [String: Any] else {
            throw AgentHookWireError.invalidMessage
        }
        if let expected = queueConfirmation,
           reply["type"] as? String == "broadcast", reply["method"] as? String == "thread-queued-followups-changed",
           reply["version"] as? Int == 2, reply["sourceClientId"] as? String == expected.owner,
           let params = reply["params"] as? [String: Any], params["hostId"] as? String == "local",
           params["conversationId"] as? String == expected.thread,
           let messages = params["messages"] as? [[String: Any]], messages.contains(where: { $0["id"] as? String == expected.id }) {
            queueObserved = true
        }
        return reply
    }

    private func exchange(_ fd: Int32, method: String, version: Int, params: [String: Any],
                          target: String? = nil, mutation: Bool = false) throws -> [String: Any] {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw AgentHookWireError.unavailable }
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "version": version, "method": method, "params": params, "timeoutMs": 10_000]
        if let target { message["targetClientId"] = target }
        let frame = try CodexDesktopWire.frame(message)
        if mutation { submitted = true }
        try AgentUnixSocket.write(frame, to: fd, until: deadline)
        while true {
            let reply = try readMessage(fd)
            // Ignore unrelated broadcasts without retaining their contents.
            guard reply["type"] as? String == "response", reply["requestId"] as? String == id else { continue }
            if reply["resultType"] as? String == "error" {
                // After a mutation, an arbitrary Desktop exception can follow
                // submission. Only routing/version rejection proves no send.
                if !mutation || ["no-client-found", "request-version-mismatch", "no-handler-for-request"]
                    .contains(reply["error"] as? String ?? "") { submitted = false }
                throw AgentHookWireError.unavailable
            }
            guard reply["resultType"] as? String == "success", reply["method"] as? String == method else {
                throw AgentHookWireError.invalidMessage
            }
            return reply
        }
    }

    private func read(_ count: Int, from fd: Int32) throws -> Data {
        guard receivedBytes + count <= 64 * 1024 * 1024 else { throw AgentHookWireError.invalidMessage }
        var result = Data()
        while result.count < count {
            try AgentUnixSocket.wait(fd, events: Int16(POLLIN), until: deadline)
            var storage = [UInt8](repeating: 0, count: min(8192, count - result.count))
            let size = Darwin.read(fd, &storage, storage.count)
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw AgentHookWireError.unavailable }
            result.append(contentsOf: storage.prefix(size))
        }
        receivedBytes += result.count
        return result
    }
}

enum CodexDesktopWire {
    // Raw owner history can exceed the retained state by an order of magnitude.
    // Check before allocating the payload; retained nodes have separate limits.
    static let maximumIncomingFrameBytes = 32 * 1024 * 1024
    static func acceptsIncomingFrame(_ count: Int) -> Bool { count > 0 && count <= maximumIncomingFrameBytes }

    static func clientID(_ response: [String: Any]) -> String? {
        guard response["resultType"] as? String == "success",
              response["method"] as? String == "initialize",
              let id = (response["result"] as? [String: Any])?["clientId"] as? String,
              AgentHookEnvelope.validID(id) else { return nil }
        return id
    }

    static func ownerID(_ response: [String: Any]) -> String? {
        guard response["resultType"] as? String == "success",
              response["method"] as? String == "thread-owner-discovery",
              let id = response["handledByClientId"] as? String, AgentHookEnvelope.validID(id),
              let result = response["result"] as? [String: Any], result["supportsUntrustedAppInput"] is Bool else { return nil }
        return id
    }

    static func validSettings(_ response: [String: Any], owner: String) -> Bool {
        guard response["resultType"] as? String == "success",
              response["method"] as? String == "thread-follower-read-model-settings",
              response["handledByClientId"] as? String == owner,
              let settings = (response["result"] as? [String: Any])?["settings"] as? [String: Any],
              settings["resumeState"] as? String == "resumed" else { return false }
        return ["model", "reasoningEffort", "threadSource", "modelProvider", "mode"].allSatisfy {
            settings[$0] == nil || settings[$0] is NSNull || settings[$0] is String
        }
    }

    static func frame(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        guard json.count > 0, json.count <= 1024 * 1024 else { throw AgentHookWireError.invalidMessage }
        var length = UInt32(json.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(json)
        return result
    }

    static func sendParams(_ request: AgentMessageRequest) -> [String: Any] {
        let id = request.id.uuidString
        return ["conversationId": request.sessionID.sessionID, "turnStart": [
            "request": ["threadId": request.sessionID.sessionID, "clientUserMessageId": id,
                        "input": [["type": "text", "text": request.text, "text_elements": []]]],
            "context": ["inheritThreadSettings": true, "restoreMessage": restoreMessage(request)]]]
    }

    static func restoreMessage(_ request: AgentMessageRequest) -> [String: Any] {
        ["id": request.id.uuidString, "text": request.text, "createdAt": Date().timeIntervalSince1970 * 1000,
         "context": ["prompt": request.text, "addedFiles": [], "fileAttachments": [],
                     "imageAttachments": [], "ideContext": NSNull()]]
    }

    static func delivery(_ response: [String: Any], owner: String) -> AgentMessageDelivery {
        guard response["handledByClientId"] as? String == owner,
              let result = (response["result"] as? [String: Any])?["result"] as? [String: Any],
              let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String,
              UUID(uuidString: id) != nil else { return .uncertain }
        return .accepted
    }
}

/// Read only the original thread's compatible local queue. The owner is the
/// only writer; never edit its global state file or discard existing entries.
enum CodexDesktopQueue {
    static func read(root: URL, thread: String) throws -> [[String: Any]] {
        let fd = open(root.appendingPathComponent(".codex-global-state.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentHookWireError.unavailable }
        defer { close(fd) }
        var info = stat()
        let limit = 8 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= limit else { throw AgentHookWireError.invalidMessage }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= limit else { throw AgentHookWireError.invalidMessage }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentHookWireError.invalidMessage }
        guard let value = object["queued-follow-ups"] else { return [] }
        guard let queues = value as? [String: Any] else { throw AgentHookWireError.invalidMessage }
        guard let value = queues[thread] else { return [] }
        guard let messages = value as? [[String: Any]], messages.count < 500,
              messages.allSatisfy({ ($0["id"] as? String)?.isEmpty == false && $0["text"] is String && $0["context"] is [String: Any] }) else { throw AgentHookWireError.invalidMessage }
        return messages
    }
}
