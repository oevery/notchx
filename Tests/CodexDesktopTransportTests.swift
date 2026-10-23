import Darwin
import Foundation
import XCTest
@testable import NotchX

private final class DesktopSocketFixture: @unchecked Sendable {
    enum Outcome { case accepted, noOwner, disconnected, routingError, wrongOwner, malformed, holdAfterSubmission, unconfirmedQueue }
    enum QueuePush {
        case beforeACK, afterACK, invalidReadback, wrongOwner, wrongThread, wrongID, wrongVersion, wrongHost
    }
    let root: URL
    private let listener: Int32
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private let onSubmission: (@Sendable () -> Void)?
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return messages }

    init(_ outcome: Outcome, onSubmission: (@Sendable () -> Void)? = nil, nativeState: [String: Any]? = nil, queuePush: QueuePush? = nil) throws {
        self.onSubmission = onSubmission
        root = try AgentFixtures.directory()
        let path = root.appendingPathComponent("ipc/ipc.sock").path
        try AgentUnixSocket.prepareDirectory(for: path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try AgentUnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 1) == 0 else {
            close(listener); throw AgentHookWireError.unavailable
        }
        let state = nativeState ?? ["id": AgentFixtures.thread, "hostId": "local", "threadSource": "user", "resumeState": "resumed",
            "threadRuntimeStatus": ["type": "idle", "activeFlags": []],
            "turns": [["turnId": "turn-1", "status": "completed", "items": []]], "requests": []]
        DispatchQueue.global().async { [self] in serve(outcome, nativeState: state, queuePush: queuePush) }
    }

    deinit { close(listener); try? FileManager.default.removeItem(at: root) }

    private func serve(_ outcome: Outcome, nativeState: [String: Any], queuePush: QueuePush?) {
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            try AgentUnixSocket.wait(listener, events: Int16(POLLIN), until: deadline)
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            while true {
                func readBytes(_ count: Int) throws -> Data {
                    var result = Data()
                    while result.count < count {
                        try AgentUnixSocket.wait(client, events: Int16(POLLIN), until: deadline)
                        var buffer = [UInt8](repeating: 0, count: count - result.count)
                        let size = Darwin.read(client, &buffer, buffer.count)
                        guard size > 0 else { throw AgentHookWireError.unavailable }
                        result.append(contentsOf: buffer.prefix(size))
                    }
                    return result
                }
                let header = try readBytes(4)
                let count = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard count > 0, count < 64 * 1024,
                      let request = try JSONSerialization.jsonObject(with: readBytes(count)) as? [String: Any],
                      let method = request["method"] as? String else { return }
                lock.lock(); messages.append(request); lock.unlock()
                var response: [String: Any] = ["type": "response", "requestId": request["requestId"] ?? NSNull(),
                    "resultType": "success", "method": method, "handledByClientId": "fixture-owner"]
                switch method {
                case "initialize": response["result"] = ["clientId": "fixture-client"]
                case "thread-owner-discovery":
                    if outcome == .noOwner { response["resultType"] = "error"; response["error"] = "no-client-found" }
                    else { response["result"] = ["supportsUntrustedAppInput": true] }
                case "thread-follower-read-model-settings": response["result"] = ["settings": ["resumeState": "resumed"]]
                case "thread-stream-following-changed":
                    guard let params = request["params"] as? [String: Any], params["following"] as? Bool == true else { return }
                    response = ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                        "sourceClientId": "fixture-owner", "params": ["conversationId": AgentFixtures.thread, "hostId": "local",
                        "change": ["type": "snapshot", "revision": 1, "conversationState": nativeState]]]
                default:
                    onSubmission?()
                    func pushQueue() throws {
                        guard let queuePush, method == "thread-follower-set-queued-follow-ups-state",
                              let state = (request["params"] as? [String: Any])?["state"] as? [String: [[String: Any]]],
                              var entries = state[AgentFixtures.thread] else { return }
                        if queuePush == .wrongID { entries[entries.count - 1]["id"] = UUID().uuidString }
                        if queuePush == .invalidReadback { try Data("invalid fixture".utf8).write(to: root.appendingPathComponent(".codex-global-state.json")) }
                        try AgentUnixSocket.write(CodexDesktopWire.frame(["type": "broadcast", "method": "thread-queued-followups-changed",
                            "version": queuePush == .wrongVersion ? 1 : 2,
                            "sourceClientId": queuePush == .wrongOwner ? "other-owner" : "fixture-owner",
                            "params": ["conversationId": queuePush == .wrongThread ? UUID().uuidString : AgentFixtures.thread,
                                "hostId": queuePush == .wrongHost ? "remote" : "local", "messages": entries]]), to: client, until: deadline)
                    }
                    if queuePush != .afterACK { try pushQueue() }
                    if outcome == .holdAfterSubmission {
                        try AgentUnixSocket.wait(client, events: Int16(POLLIN), until: deadline)
                        var byte: UInt8 = 0
                        _ = Darwin.read(client, &byte, 1)
                        return
                    }
                    if outcome == .disconnected { return }
                    if outcome == .malformed {
                        try AgentUnixSocket.write(Data([255, 255, 255, 255]), to: client, until: deadline); return
                    }
                    if outcome == .routingError { response["resultType"] = "error"; response["error"] = "client-disconnected" }
                    if outcome == .wrongOwner { response["handledByClientId"] = "other-owner" }
                    if method == "thread-follower-start-turn" { response["result"] = ["result": ["turn": ["id": UUID().uuidString]]] }
                    else if method == "thread-follower-steer-turn" { response["result"] = ["result": ["turnId": "turn-1"]] }
                    else {
                        response["result"] = ["ok": true]
                        if method == "thread-follower-set-queued-follow-ups-state", outcome != .unconfirmedQueue,
                           let params = request["params"] as? [String: Any], let queued = params["state"] as? [String: Any] {
                            let path = root.appendingPathComponent(".codex-global-state.json")
                            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                            var queues = object["queued-follow-ups"] as? [String: Any] ?? [:]
                            for (key, value) in queued { queues[key] = value }
                            object["queued-follow-ups"] = queues
                            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
                        }
                    }
                }
                // Exercise fragmented length prefixes and UTF-8 frames.
                let frame = try CodexDesktopWire.frame(response)
                try AgentUnixSocket.write(Data(frame.prefix(2)), to: client, until: deadline)
                try AgentUnixSocket.write(Data(frame.dropFirst(2)), to: client, until: deadline)
                if method == "thread-follower-set-queued-follow-ups-state", let queuePush,
                   [.wrongOwner, .wrongThread, .wrongID, .wrongVersion, .wrongHost].contains(queuePush) {
                    // The invalid push precedes a valid ACK on the same stream, so
                    // the real parser must consume it before delivery is decided.
                    // EOF now means no further proof, instead of five identical
                    // one-second waits. The no-push case still tests the real timeout.
                    return
                }
                if method == "thread-follower-set-queued-follow-ups-state", queuePush == .afterACK,
                   let entries = (request["params"] as? [String: Any])?["state"] as? [String: [[String: Any]]] {
                    try AgentUnixSocket.write(CodexDesktopWire.frame(["type": "broadcast", "method": "thread-queued-followups-changed",
                        "version": 2, "sourceClientId": "fixture-owner", "params": ["conversationId": AgentFixtures.thread,
                            "hostId": "local", "messages": entries[AgentFixtures.thread] ?? []]]), to: client, until: deadline)
                }
            }
        } catch { /* A cancelled/disconnected client is expected in several fixtures. */ }
    }
}

final class CodexDesktopTransportTests: XCTestCase {
    private func messageState(running: Bool = true) -> [String: Any] {
        ["id": AgentFixtures.thread, "hostId": "local", "threadSource": "user", "resumeState": "resumed",
         "threadRuntimeStatus": ["type": running ? "active" : "idle", "activeFlags": []],
         "turns": [["turnId": "turn-1", "status": running ? "inProgress" : "completed", "items": []]], "requests": []]
    }

    func testPinnedOwnerSteerAndSendPreflightOriginalTurnWithoutOverrides() async throws {
        for mode in [AgentMessageMode.steer, .send] {
            let fixture = try DesktopSocketFixture(.accepted, nativeState: messageState(running: mode == .steer))
            let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: mode, text: request.text)
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, .accepted)
            let method = mode == .send ? "thread-follower-start-turn" : "thread-follower-steer-turn"
            let writes = fixture.requests.filter { $0["method"] as? String == method }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?["targetClientId"] as? String, "fixture-owner")
            if mode == .steer {
                let params = try XCTUnwrap(writes.first?["params"] as? [String: Any])
                XCTAssertEqual(params["clientUserMessageId"] as? String, message.id.uuidString)
                XCTAssertEqual((params["restoreMessage"] as? [String: Any])?["text"] as? String, message.text)
                XCTAssertNil(params["expectedTurnId"], "Desktop follower steers latest work; it has no strict expected-turn parameter")
            }
        }
    }

    func testQueuePreservesExistingEntriesAndRequiresOwnerAndReadbackConfirmation() async throws {
        for outcome in [DesktopSocketFixture.Outcome.accepted, .unconfirmedQueue, .disconnected] {
            let fixture = try DesktopSocketFixture(outcome, nativeState: messageState())
            let prior: [String: Any] = ["id": UUID().uuidString, "text": "prior Desktop message", "createdAt": 1,
                "context": ["prompt": "prior Desktop message", "fileAttachments": [["path": "/fixture/existing"]]],
                "submission": ["status": "pending"]]
            let foreign = UUID().uuidString
            let object: [String: Any] = ["queued-follow-ups": [AgentFixtures.thread: [prior], foreign: [prior]], "unrelated": "preserve"]
            let path = fixture.root.appendingPathComponent(".codex-global-state.json")
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .queue, text: request.text)
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, outcome == .accepted ? .accepted : .uncertain)
            let writes = fixture.requests.filter { $0["method"] as? String == "thread-follower-set-queued-follow-ups-state" }
            XCTAssertEqual(writes.count, 1, "No retry after a missing acknowledgement or uncertain readback")
            let params = try XCTUnwrap(writes.first?["params"] as? [String: Any])
            let state = try XCTUnwrap(params["state"] as? [String: [[String: Any]]])
            XCTAssertEqual(Set(state.keys), [AgentFixtures.thread], "Do not write another conversation's queue")
            let entries = try XCTUnwrap(state[AgentFixtures.thread])
            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(NSDictionary(dictionary: entries[0]).isEqual(to: prior))
            XCTAssertEqual(entries[1]["id"] as? String, message.id.uuidString)
            XCTAssertEqual(entries[1]["text"] as? String, message.text)
            XCTAssertTrue((params["discardedMessageIds"] as? [String])?.isEmpty == true)
        }
    }

    func testMessagePreflightRejectsChangedOwnerTurnAndWaitingStateWithoutSubmission() async throws {
        let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .steer, text: "original only")
        for (state, owner) in [(messageState(), "old-owner"), (messageState(running: false), "fixture-owner"), (nativeQuestion(), "fixture-owner")] {
            let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: owner)
            XCTAssertEqual(result, .failed)
            XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread-follower-steer-turn" })
        }
        let fixture = try DesktopSocketFixture(.accepted, nativeState: messageState())
        let stale = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "old-turn", mode: .steer, text: "stale")
        let result = await CodexDesktopTransport.send(stale, root: fixture.root, owner: "fixture-owner")
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread-follower-steer-turn" })
    }

    func testQueueStoreRejectsMalformedUnownedShapeAndSymlinks() throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".codex-global-state.json")
        try Data(#"{"queued-follow-ups":false}"#.utf8).write(to: path)
        XCTAssertThrowsError(try CodexDesktopQueue.read(root: root, thread: AgentFixtures.thread))
        try FileManager.default.removeItem(at: path)
        let target = root.appendingPathComponent("foreign")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        XCTAssertThrowsError(try CodexDesktopQueue.read(root: root, thread: AgentFixtures.thread))
    }

    func testQueuePushConfirmsConsumedEntryBeforeOrAfterACKWithoutReadback() async throws {
        for push in [DesktopSocketFixture.QueuePush.beforeACK, .afterACK, .invalidReadback] {
            let fixture = try DesktopSocketFixture(.unconfirmedQueue, nativeState: messageState(), queuePush: push)
            try Data("{}".utf8).write(to: fixture.root.appendingPathComponent(".codex-global-state.json"))
            let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .queue, text: "consumed before readback")
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, .accepted, "Confirmed push must survive consumed/missing readback: \(push)")
            XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-set-queued-follow-ups-state" }.count, 1)
        }
    }

    func testUnrelatedQueuePushCannotConfirmAnOriginalSessionMessage() async throws {
        for push in [DesktopSocketFixture.QueuePush.wrongOwner, .wrongThread, .wrongID, .wrongVersion, .wrongHost] {
            let fixture = try DesktopSocketFixture(.unconfirmedQueue, nativeState: messageState(), queuePush: push)
            try Data("{}".utf8).write(to: fixture.root.appendingPathComponent(".codex-global-state.json"))
            let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .queue, text: "original only")
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, .uncertain, "Unrelated push: \(push)")
            XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-set-queued-follow-ups-state" }.count, 1)
        }
    }

    func testQueuePushWithoutOwnerACKRemainsUncertainWithoutRetry() async throws {
        for outcome in [DesktopSocketFixture.Outcome.disconnected, .wrongOwner] {
            let fixture = try DesktopSocketFixture(outcome, nativeState: messageState(), queuePush: .beforeACK)
            try Data("{}".utf8).write(to: fixture.root.appendingPathComponent(".codex-global-state.json"))
            let message = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .queue, text: "no owner acknowledgement")
            let result = await CodexDesktopTransport.send(message, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, .uncertain)
            XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-set-queued-follow-ups-state" }.count, 1)
        }
    }
    private func nativeQuestion(_ text: String = "Choose a viewport", requestID: Any = 141, turn: String = "turn-1") -> [String: Any] {
        ["id": AgentFixtures.thread, "hostId": "local", "threadSource": "user", "resumeState": "resumed",
         "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnUserInput"]],
         "turns": [["turnId": turn, "status": "inProgress", "items": []]],
         "requests": [["id": requestID, "method": "item/tool/requestUserInput", "params": [
            "threadId": AgentFixtures.thread, "turnId": turn, "itemId": "question-tool",
            "questions": [["id": "viewport", "header": "Viewport", "question": text, "isSecret": false, "isOther": true,
                "options": [["label": "Desktop", "description": "Use a wide viewport"]]]]]]]]
    }
    private func input(_ state: [String: Any]) throws -> AgentPendingInput {
        let raw = try XCTUnwrap((state["requests"] as? [[String: Any]])?.first)
        let params = try XCTUnwrap(raw["params"] as? [String: Any])
        return try XCTUnwrap(CodexNativeRequests.input(params: params, id: CodexNativeRequests.key(kind: .desktop,
            thread: AgentFixtures.thread, turn: params["turnId"] as! String, id: XCTUnwrap(CodexNativeRequestID(raw["id"])))) )
    }
    private func answer(_ input: AgentPendingInput) -> AgentInputResponse {
        AgentInputResponse(requestID: input.id, sessionID: CodexAgentState.id(AgentFixtures.thread), turnID: "turn-1",
            answers: ["viewport": ["Literal $(answer) `text`\n第二行"]])
    }

    private func nativeApproval(command: String = "printf fixture", reviewer: String = "user", file: Bool = false) -> [String: Any] {
        let params: [String: Any] = ["threadId": AgentFixtures.thread, "turnId": "turn-1", "itemId": "approval-tool",
            "kind": "command", "command": command, "availableDecisions": ["accept", "cancel"]]
        return ["id": AgentFixtures.thread, "hostId": "local", "threadSource": "user", "resumeState": "resumed",
            "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
            "turns": [["turnId": "turn-1", "status": "inProgress", "params": ["approvalsReviewer": reviewer],
                "items": file ? [["id": "approval-tool", "type": "fileChange", "status": "inProgress",
                    "changes": [["path": "/fixture/one.swift", "kind": ["type": "add"]],
                                ["path": "/fixture/two.swift", "kind": ["type": "update", "move_path": NSNull()]]]]] : []]],
            "requests": [["id": "approval-1", "method": file ? "item/fileChange/requestApproval" : "item/commandExecution/requestApproval",
                "params": params]]]
    }

    private func approval(_ state: [String: Any]) throws -> AgentApproval {
        let projected = try XCTUnwrap(CodexDesktopProjection.snapshot(state, thread: AgentFixtures.thread, parent: nil, revision: 1))
        return try XCTUnwrap(projected.approvals.first)
    }

    func testNativeApprovalUsesOriginalRequestAndDistinguishesCancelFromDecline() async throws {
        let state = nativeApproval(), reviewed = try approval(state)
        XCTAssertTrue(reviewed.denyEndsTurn)
        let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
        let result = await CodexDesktopTransport.respond(approval: reviewed, decision: .deny, owner: "fixture-owner", root: fixture.root)
        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(fixture.requests.first { $0["method"] as? String == "thread-follower-command-approval-decision" })
        let params = try XCTUnwrap(submission["params"] as? [String: Any])
        XCTAssertEqual(params["requestId"] as? String, "approval-1")
        XCTAssertEqual(params["decision"] as? String, "cancel")
        XCTAssertFalse(params.keys.contains("execpolicyAmendment"))
    }

    func testNativeApprovalRejectsChangedCommandAndNonHumanReview() async throws {
        let reviewed = try approval(nativeApproval())
        for state in [nativeApproval(command: "different command"), nativeApproval(reviewer: "auto_review"), nativeApproval(reviewer: "")] {
            let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
            let result = await CodexDesktopTransport.respond(approval: reviewed, decision: .allow, owner: "fixture-owner", root: fixture.root)
            XCTAssertEqual(result, .failed)
            XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread-follower-command-approval-decision" })
        }
    }

    func testNativeFileApprovalShowsCompletePathsAndUsesSeparateRoute() async throws {
        let state = nativeApproval(file: true), reviewed = try approval(state)
        XCTAssertEqual(reviewed.command, "/fixture/one.swift\n/fixture/two.swift")
        let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
        let result = await CodexDesktopTransport.respond(approval: reviewed, decision: .allow, owner: "fixture-owner", root: fixture.root)
        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(fixture.requests.first { $0["method"] as? String == "thread-follower-file-approval-decision" })
        XCTAssertEqual((submission["params"] as? [String: Any])?["decision"] as? String, "accept")
    }

    func testNativeAnswerRevalidatesQuestionAndPreservesNumericRequestID() async throws {
        let state = nativeQuestion(), input = try input(state), response = answer(input)
        let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
        let result = await CodexDesktopTransport.respondToInput(response, input: input, owner: "fixture-owner", root: fixture.root)
        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(fixture.requests.first { $0["method"] as? String == "thread-follower-submit-user-input" })
        XCTAssertEqual(submission["targetClientId"] as? String, "fixture-owner")
        let params = try XCTUnwrap(submission["params"] as? [String: Any])
        XCTAssertTrue(params["requestId"] is NSNumber)
        XCTAssertEqual(params["requestId"] as? Int, 141)
        let answers = try XCTUnwrap((params["response"] as? [String: Any])?["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["viewport"]?["answers"], response.answers["viewport"])
        XCTAssertFalse(fixture.requests.contains { ($0["method"] as? String)?.contains("start-turn") == true })
    }

    func testNativeAnswerCannotTargetChangedQuestionTurnOrOwner() async throws {
        let reviewed = try input(nativeQuestion()), response = answer(reviewed)
        for state in [nativeQuestion("Changed question"), nativeQuestion(turn: "turn-2"), nativeQuestion(requestID: "141")] {
            let fixture = try DesktopSocketFixture(.accepted, nativeState: state)
            let result = await CodexDesktopTransport.respondToInput(response, input: reviewed, owner: "fixture-owner", root: fixture.root)
            XCTAssertEqual(result, .failed)
            XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread-follower-submit-user-input" })
        }
        let fixture = try DesktopSocketFixture(.accepted, nativeState: nativeQuestion())
        let result = await CodexDesktopTransport.respondToInput(response, input: reviewed, owner: "old-owner", root: fixture.root)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testNativeAnswerLostAcknowledgementIsUncertainAndNeverRetried() async throws {
        let state = nativeQuestion(), input = try input(state)
        let fixture = try DesktopSocketFixture(.disconnected, nativeState: state)
        let result = await CodexDesktopTransport.respondToInput(answer(input), input: input, owner: "fixture-owner", root: fixture.root)
        XCTAssertEqual(result, .uncertain)
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-submit-user-input" }.count, 1)
    }

    private var request: AgentMessageRequest {
        AgentMessageRequest(id: UUID(), sessionID: CodexAgentState.id(AgentFixtures.thread),
                            turnID: "turn-1", mode: .send, text: "原文 $(literal) `text`\n第二行")
    }

    func testExistingOwnerReceivesOneExactMessageWithInheritedSettings() async throws {
        let fixture = try DesktopSocketFixture(.accepted), request = request
        let result = await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner")
        XCTAssertEqual(result, .accepted)
        let messages = fixture.requests
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }.filter { $0 != "thread-stream-following-changed" },
                       ["initialize", "thread-owner-discovery", "thread-follower-read-model-settings", "thread-follower-start-turn"])
        let last = try XCTUnwrap(messages.first { $0["method"] as? String == "thread-follower-start-turn" })
        XCTAssertEqual(last["targetClientId"] as? String, "fixture-owner")
        let params = try XCTUnwrap(last["params"] as? [String: Any])
        XCTAssertEqual(params["conversationId"] as? String, request.sessionID.sessionID)
        let start = try XCTUnwrap(params["turnStart"] as? [String: Any])
        let body = try XCTUnwrap(start["request"] as? [String: Any])
        XCTAssertEqual(body["threadId"] as? String, request.sessionID.sessionID)
        XCTAssertEqual((body["input"] as? [[String: Any]])?.first?["text"] as? String, request.text)
        XCTAssertNil(body["model"]); XCTAssertNil(body["approvalPolicy"]); XCTAssertNil(body["sandboxPolicy"])
        XCTAssertEqual((start["context"] as? [String: Any])?["inheritThreadSettings"] as? Bool, true)
    }

    func testUnloadedOwnerFailsWithoutStartingOrResumingAnything() async throws {
        let fixture = try DesktopSocketFixture(.noOwner), request = request
        let result = await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner")
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testMissingOrUntrustedAcknowledgementsPreserveUncertaintyWithoutRetry() async throws {
        for outcome in [DesktopSocketFixture.Outcome.disconnected, .routingError, .wrongOwner, .malformed] {
            let fixture = try DesktopSocketFixture(outcome), request = request
            let result = await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner")
            XCTAssertEqual(result, .uncertain)
            XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-start-turn" }.count, 1)
        }
    }

    func testCancelledSendAndUnsafeDirectoryCannotSubmit() async throws {
        let fixture = try DesktopSocketFixture(.accepted), request = request
        let pending = Task { await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner") }
        pending.cancel()
        let cancelled = await pending.value
        XCTAssertEqual(cancelled, .failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.appendingPathComponent("ipc").path)
        let unsafe = await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner")
        XCTAssertEqual(unsafe, .failed)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testCancellationUnblocksInFlightReadAndKeepsDeliveryUnconfirmed() async throws {
        let submitted = expectation(description: "Desktop received the request")
        let fixture = try DesktopSocketFixture(.holdAfterSubmission, onSubmission: { submitted.fulfill() })
        let request = request
        let pending = Task { await CodexDesktopTransport.send(request, root: fixture.root, owner: "fixture-owner") }
        await fulfillment(of: [submitted], timeout: 3)
        let cancelledAt = ContinuousClock.now
        pending.cancel()
        let result = await pending.value
        XCTAssertEqual(result, .uncertain)
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2), "Cancellation must unblock the socket read rather than await its deadline")
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread-follower-start-turn" }.count, 1)
    }

}
