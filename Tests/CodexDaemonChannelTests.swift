import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NotchX

private final class DaemonSocketFixture: @unchecked Sendable {
    enum Outcome: Equatable {
        case normal, unloaded, unmaterialized, wrongResume, streamEvents, nativeRequests, nativeUnresolved, nativeAutoReview, nativeFiles, queueEvents
        case queueWrongClient, queueMissingID, queueLostACK, steerWrongTurn
        case children, earlyChild, invalidUpgrade, oversizedFrame, disconnectMutation, holdMutation, rpcError(Int)
        var usesQueueEvents: Bool { [.queueEvents, .queueWrongClient, .queueMissingID, .queueLostACK, .steerWrongTurn].contains(self) }
        var usesNativeEvents: Bool { usesQueueEvents || [.nativeRequests, .nativeUnresolved, .nativeAutoReview, .nativeFiles].contains(self) }
    }
    static let thread = "01a156b9-bfc7-71c1-a986-7ccc73faf51e"
    static let child = "01a156b9-bfc7-71c1-a986-7ccc73faf51f"
    static let foreign = "01a156b9-bfc7-71c1-a986-7ccc73faf510"
    let root: URL
    let physical: String
    let advertised: String
    private let listener: Int32
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private let onMutation: (@Sendable () -> Void)?
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return messages }

    init(_ outcome: Outcome = .normal, onMutation: (@Sendable () -> Void)? = nil) throws {
        self.onMutation = onMutation
        root = URL(fileURLWithPath: "/private/tmp/nxd-" + String(UUID().uuidString.prefix(12)))
        physical = root.appendingPathComponent("s").path
        advertised = root.appendingPathComponent("app-server-control/app-server-control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app-server-control"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try AgentUnixSocket.address(physical)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(physical, 0o600) == 0, listen(listener, 2) == 0 else {
            close(listener); throw AgentHookWireError.unavailable
        }
        try FileManager.default.createSymbolicLink(atPath: advertised, withDestinationPath: physical)
        if outcome == .nativeFiles { try writePendingFile(name: "first.txt") }
        DispatchQueue.global().async { [self] in serve(outcome) }
    }

    deinit { close(listener); try? FileManager.default.removeItem(at: root) }

    func stop() {
        _ = shutdown(listener, SHUT_RDWR)
        try? FileManager.default.removeItem(at: root)
    }

    func writePendingFile(name: String) throws {
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records: [[String: Any]] = [["type": "session_meta", "payload": ["id": Self.thread]],
            ["type": "turn_context", "payload": ["turn_id": "turn-2", "cwd": root.path]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "file-1",
                "input": "*** Begin Patch\n*** Add File: " + name + "\n+fixture\n*** End Patch",
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-2"]]]]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: folder.appendingPathComponent("fixture.jsonl"))
    }

    private func serve(_ outcome: Outcome) {
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            try AgentUnixSocket.wait(listener, events: Int16(POLLIN), until: deadline)
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            func exact(_ count: Int) throws -> Data {
                var data = Data()
                while data.count < count {
                    try AgentUnixSocket.wait(client, events: Int16(POLLIN), until: deadline)
                    var bytes = [UInt8](repeating: 0, count: count - data.count)
                    let size = Darwin.read(client, &bytes, bytes.count)
                    guard size > 0 else { throw AgentHookWireError.unavailable }
                    data.append(contentsOf: bytes.prefix(size))
                }
                return data
            }
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 8192 { header.append(try exact(1)) }
            let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            guard let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }),
                  let key = keyLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else { return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
                + (outcome == .invalidUpgrade ? "incorrect" : accept) + "\r\n\r\n"
            try AgentUnixSocket.write(Data(response.utf8), to: client, until: deadline)
            if outcome == .invalidUpgrade { return }
            if outcome == .oversizedFrame {
                try AgentUnixSocket.write(Data([0x81, 127, 0, 0, 0, 0, 2, 0, 0, 0]), to: client, until: deadline)
                return
            }
            func frame(_ payload: Data, opcode: UInt8 = 1, final: Bool = true) throws {
                var data = Data([(final ? 0x80 : 0) | opcode])
                if payload.count < 126 { data.append(UInt8(payload.count)) }
                else { data.append(126); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255)) }
                data.append(payload)
                // Fragment byte delivery independently of WebSocket message fragmentation.
                try AgentUnixSocket.write(Data(data.prefix(1)), to: client, until: deadline)
                try AgentUnixSocket.write(Data(data.dropFirst()), to: client, until: deadline)
            }
            var resumed = false, emitted = false
            for _ in 0..<80 {
                let prefix = [UInt8](try exact(2))
                guard prefix[0] & 0x80 != 0, prefix[1] & 0x80 != 0 else { return }
                var count = Int(prefix[1] & 127)
                if count == 126 { count = try exact(2).reduce(0) { $0 << 8 | Int($1) } }
                else if count == 127 { count = try exact(8).reduce(0) { $0 << 8 | Int($1) } }
                guard count < 64 * 1024 else { return }
                let mask = [UInt8](try exact(4)), bytes = try exact(count)
                let payload = Data(bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
                if prefix[0] & 15 == 10 { continue }
                guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
                lock.lock(); messages.append(request); lock.unlock()
                if request["method"] == nil, let id = request["id"], request["result"] != nil {
                    if outcome != .nativeUnresolved {
                        try frame(JSONSerialization.data(withJSONObject: ["method": "serverRequest/resolved", "params": ["threadId": Self.thread, "requestId": id]]))
                    }
                    continue
                }
                guard let method = request["method"] as? String else { return }
                guard let id = request["id"] else { continue }
                let threadID = (request["params"] as? [String: Any])?["threadId"] as? String ?? Self.thread
                var metadata = Self.metadata
                metadata["id"] = threadID
                if outcome == .nativeFiles { metadata["cwd"] = root.path; metadata["path"] = root.appendingPathComponent("sessions/fixture.jsonl").path }
                if outcome == .children, threadID == Self.child {
                    metadata["parentThreadId"] = Self.thread
                    metadata["status"] = ["type": "active", "activeFlags": []]
                }
                if ["turn/start", "turn/steer", "config/batchWrite"].contains(method) {
                    onMutation?()
                    if outcome == .disconnectMutation { return }
                    if outcome == .holdMutation {
                        try AgentUnixSocket.wait(client, events: Int16(POLLIN), until: deadline)
                        _ = try? exact(1); return
                    }
                    if case .rpcError(let code) = outcome {
                        try frame(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": code, "message": "fixture error"]]))
                        continue
                    }
                }
                let result: [String: Any]
                switch method {
                case "initialize": result = ["userAgent": "fixture"]
                case "thread/loaded/list": result = ["data": outcome == .unloaded ? [] : (outcome == .children ? [Self.thread, Self.child, Self.foreign] : [Self.thread])]
                case "thread/read": result = ["thread": metadata]
                case "thread/turns/list":
                    if outcome == .unmaterialized {
                        try frame(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32600, "message": "thread \(Self.thread) is not materialized yet; thread/turns/list is unavailable before first user message"]]))
                        continue
                    }
                    result = ["data": [["id": "turn-1", "status": "completed", "items": []]]]
                case "thread/resume":
                    resumed = true
                    var thread = metadata
                    if outcome == .wrongResume { thread["id"] = UUID().uuidString }
                    thread["turns"] = []
                    result = ["thread": thread, "approvalsReviewer": outcome == .nativeAutoReview ? "guardian_subagent" : "user"]
                case "thread/unsubscribe": result = ["status": "unsubscribed"]
                case "thread/queue/list":
                    if outcome.usesNativeEvents { result = ["data": []] }
                    else {
                        try frame(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32601, "message": "queue unavailable"]]))
                        continue
                    }
                case "thread/queue/add":
                    if outcome == .queueLostACK { return }
                    let params = request["params"] as? [String: Any] ?? [:]
                    var queued: [String: Any] = ["id": "queued-1", "clientUserMessageId": outcome == .queueWrongClient ? "another-message" : params["clientUserMessageId"] ?? "", "input": params["input"] ?? []]
                    if outcome == .queueMissingID { queued.removeValue(forKey: "id") }
                    result = ["queuedSubmission": queued]
                case "turn/start": result = ["turn": ["id": "turn-2", "status": "inProgress"]]
                case "turn/steer": result = ["turnId": outcome == .steerWrongTurn ? "other-turn" : outcome.usesQueueEvents ? "turn-2" : "turn-1"]
                case "hooks/list": result = ["data": []]
                case "config/read": result = ["version": "fixture-version"]
                case "config/batchWrite": result = ["version": "fixture-next-version"]
                default: return
                }
                let encoded = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
                try frame(Data([7]), opcode: 9)
                let middle = encoded.count / 2
                try frame(Data(encoded.prefix(middle)), final: false)
                try frame(Data(encoded.dropFirst(middle)), opcode: 0)
                if outcome.usesNativeEvents, resumed, !emitted, method == "thread/loaded/list" {
                    emitted = true
                    usleep(150_000)
                    try frame(JSONSerialization.data(withJSONObject: ["method": "turn/started", "params": ["threadId": Self.thread, "turn": ["id": "turn-2", "status": "inProgress"]]]))
                    if outcome == .nativeFiles {
                        try frame(JSONSerialization.data(withJSONObject: ["id": "file-request", "method": "item/fileChange/requestApproval", "params": ["threadId": Self.thread, "turnId": "turn-2", "itemId": "file-1", "grantRoot": NSNull()]]))
                    } else if !outcome.usesQueueEvents {
                        try frame(JSONSerialization.data(withJSONObject: ["id": 7, "method": "item/tool/requestUserInput", "params": ["threadId": Self.thread, "turnId": "turn-2", "itemId": "question-1", "isBlocking": true,
                            "questions": [["id": "choice", "header": "Fixture", "question": "Choose", "isSecret": false, "isOther": true, "options": [["label": "A", "description": "First"]]]]]]))
                        for id in ["7", "8"] {
                            try frame(JSONSerialization.data(withJSONObject: ["id": id, "method": "item/commandExecution/requestApproval", "params": ["threadId": Self.thread, "turnId": "turn-2", "itemId": id, "kind": "command", "command": "printf fixture", "availableDecisions": ["accept", "cancel"]]]))
                        }
                    }
                }
                if outcome == .earlyChild, resumed, !emitted, method == "thread/loaded/list" {
                    emitted = true
                    usleep(150_000)
                    let child: [String: Any] = ["id": Self.child, "parentThreadId": Self.thread, "status": ["type": "active"],
                        "source": ["subAgent": ["thread_spawn": ["parent_thread_id": Self.thread]]], "agentNickname": "Early"]
                    try frame(JSONSerialization.data(withJSONObject: ["method": "thread/started", "params": ["thread": child]]))
                    for method in ["turn/started", "turn/completed"] {
                        try frame(JSONSerialization.data(withJSONObject: ["method": method, "params": ["threadId": Self.child,
                            "turn": ["id": "child-turn", "status": method == "turn/started" ? "inProgress" : "completed"]]]))
                    }
                }
                if outcome == .streamEvents, resumed, !emitted, method == "thread/loaded/list" {
                    emitted = true
                    // Deliver only after bootstrap completed, with no client RPC
                    // required to wake the production persistent reader.
                    usleep(150_000)
                    let samples: [(String, [String: Any])] = [
                        ("turn/started", ["turn": ["id": "turn-2", "status": "inProgress", "startedAt": 1_800_000_000]]),
                        ("item/started", ["turnId": "turn-2", "item": ["type": "commandExecution", "id": "cmd-1", "command": "swift test", "status": "inProgress"]]),
                        ("item/completed", ["turnId": "turn-2", "item": ["type": "commandExecution", "id": "cmd-1", "command": "swift test", "status": "completed", "aggregatedOutput": "SECRET OUTPUT"]])
                    ]
                    for (method, values) in samples {
                        var params = values; params["threadId"] = Self.thread
                        try frame(JSONSerialization.data(withJSONObject: ["method": method, "params": params]))
                    }
                    _ = shutdown(client, SHUT_RDWR)
                    return
                }
            }
        } catch { /* EOF/cancellation is an expected fixture boundary. */ }
    }

    static var metadata: [String: Any] {
        ["id": thread, "source": "cli", "name": "fixture", "canAcceptDirectInput": true,
         "status": ["type": "idle"], "updatedAt": 1_700_000_000]
    }
}

final class CodexDaemonChannelTests: XCTestCase {
    @MainActor func testFileApprovalExtractsExactPendingCallAndRechecksPathsBeforeReply() async throws {
        let fixture = try DaemonSocketFixture(.nativeFiles)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        defer { channel.stop() }
        var latest: CodexPrimarySnapshot?
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
        try await NativeUI.waitFor("pending file paths available before approval") { latest?.approvals.count == 1 }
        let approval = try XCTUnwrap(latest?.approvals.first)
        XCTAssertEqual(approval.tool, "apply_patch")
        XCTAssertEqual(approval.command, fixture.root.appendingPathComponent("first.txt").path)
        try fixture.writePendingFile(name: "changed.txt")
        let changed = await channel.respond(approval: approval, decision: .allow)
        XCTAssertEqual(changed, .failed)
        XCTAssertFalse(fixture.requests.contains { $0["method"] == nil && $0["result"] != nil })
        try fixture.writePendingFile(name: "first.txt")
        let accepted = await channel.respond(approval: approval, decision: .allow)
        XCTAssertEqual(accepted, .accepted)
        XCTAssertTrue(latest?.approvals.isEmpty ?? false)
    }

    @MainActor func testEarlyChildEventsAreNotUnsubscribedAndKeepParentLastKnownStatus() async throws {
        let fixture = try DaemonSocketFixture(.earlyChild)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        defer { channel.stop() }
        var values: [String: CodexPrimarySnapshot] = [:]
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { values[value.threadID] = value } }
        try await NativeUI.waitFor("early child reaches completion") { values[DaemonSocketFixture.child]?.status == .completed }
        XCTAssertEqual(values[DaemonSocketFixture.thread]?.observedChildren.first?.context.lastKnownStatus, .completed)
        XCTAssertEqual(values[DaemonSocketFixture.thread]?.observedChildren.first?.status, .unknown)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread/unsubscribe" })
        channel.updateThreads([])
        try await NativeUI.waitFor("parent and early child released") { fixture.requests.filter { $0["method"] as? String == "thread/unsubscribe" }.count == 2 }
    }

    @MainActor func testNativeApprovalWithAutomaticReviewerStaysNonActionable() async throws {
        let fixture = try DaemonSocketFixture(.nativeAutoReview)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        defer { channel.stop() }
        var latest: CodexPrimarySnapshot?
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
        try await NativeUI.waitFor("native approvals checked against current owner reviewer") {
            latest?.status == .waitingApproval && fixture.requests.filter { $0["method"] as? String == "thread/resume" }.count >= 3
        }
        XCTAssertTrue(latest?.approvals.isEmpty ?? false)
        XCTAssertFalse(latest?.capabilities.contains(.approvals) ?? true)
        XCTAssertFalse(fixture.requests.contains { $0["method"] == nil && $0["result"] != nil })
    }

    @MainActor func testNativeInputAndConcurrentApprovalsResolveOnlyTheirOwnTypedHandles() async throws {
        let fixture = try DaemonSocketFixture(.nativeRequests)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60, timeout: 0.4)
        defer { channel.stop() }
        var latest: CodexPrimarySnapshot?
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
        try await NativeUI.waitFor("native handles delivered") { latest?.context.pendingInput?.canRespond == true && latest?.approvals.count == 2 }
        let input = try XCTUnwrap(latest?.context.pendingInput)
        let approvals = try XCTUnwrap(latest?.approvals)
        XCTAssertNotEqual(input.id, approvals[0].id, "Numeric and string request IDs cannot alias")
        XCTAssertEqual(input.questions.first?.id, "choice")
        let wrongTurn = AgentInputResponse(requestID: input.id, sessionID: CodexAgentState.id(DaemonSocketFixture.thread), turnID: "stale-turn", answers: ["choice": ["A"]])
        let rejected = await channel.respondToInput(wrongTurn)
        XCTAssertEqual(rejected, .failed)
        let response = AgentInputResponse(requestID: input.id, sessionID: wrongTurn.sessionID, turnID: "turn-2", answers: ["choice": ["literal $(answer)"]])
        let answered = await channel.respondToInput(response)
        XCTAssertEqual(answered, .accepted)
        XCTAssertNil(latest?.context.pendingInput)
        XCTAssertEqual(latest?.approvals.count, 2)
        XCTAssertTrue(approvals[0].canDeny)
        XCTAssertTrue(approvals[0].denyEndsTurn, "Cancel must be exposed with its turn-ending semantics")
        let unsupported = await channel.respond(approval: approvals[0], decision: .deferToApp)
        XCTAssertEqual(unsupported, .failed)
        let allowed = await channel.respond(approval: approvals[0], decision: .allow)
        XCTAssertEqual(allowed, .accepted)
        XCTAssertEqual(latest?.approvals.count, 1)
        let duplicate = await channel.respond(approval: approvals[0], decision: .allow)
        XCTAssertEqual(duplicate, .failed)
        let cancelled = await channel.respond(approval: approvals[1], decision: .deny)
        XCTAssertEqual(cancelled, .accepted)
        let replies = fixture.requests.filter { $0["method"] == nil && $0["result"] != nil }
        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(CodexNativeRequestID(replies.first?["id"]), .number(7))
        XCTAssertEqual(CodexNativeRequestID(replies[1]["id"]), .string("7"))
        XCTAssertEqual((replies.last?["result"] as? [String: Any])?["decision"] as? String, "cancel")
    }

    @MainActor func testNativeResponseWithoutResolutionIsUncertainAndNeverReanswered() async throws {
        let fixture = try DaemonSocketFixture(.nativeUnresolved)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60, timeout: 0.1)
        defer { channel.stop() }
        var latest: CodexPrimarySnapshot?
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
        try await NativeUI.waitFor("question available") { latest?.context.pendingInput?.canRespond == true }
        let input = try XCTUnwrap(latest?.context.pendingInput)
        let response = AgentInputResponse(requestID: input.id, sessionID: CodexAgentState.id(DaemonSocketFixture.thread), turnID: "turn-2", answers: ["choice": ["A"]])
        let uncertain = await channel.respondToInput(response)
        XCTAssertEqual(uncertain, .uncertain)
        let duplicate = await channel.respondToInput(response)
        XCTAssertEqual(duplicate, .failed)
        XCTAssertEqual(fixture.requests.filter { $0["method"] == nil && $0["result"] != nil }.count, 1)
        XCTAssertTrue(latest?.context.pendingInput?.canRespond ?? false, "Unknown receipt keeps the question visible; the transport prevents resubmission")
        channel.stop()
        let afterStop = await channel.respondToInput(response)
        XCTAssertEqual(afterStop, .failed)
    }

    @MainActor func testResidentQueueProbeAndNativeSteerQueueUseOriginalConnection() async throws {
        let fixture = try DaemonSocketFixture(.queueEvents)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        defer { channel.stop() }
        var latest: CodexPrimarySnapshot?
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
        try await NativeUI.waitFor("original running thread supports queue") { latest?.capabilities.contains([.queue, .steer]) == true }
        let attachments = fixture.requests.filter { $0["method"] as? String == "thread/resume" }
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual((attachments.first?["params"] as? [String: Any])?["threadId"] as? String, DaemonSocketFixture.thread)
        for mode in [AgentMessageMode.steer, .queue] {
            let request = AgentMessageRequest(id: UUID(), sessionID: CodexAgentState.id(DaemonSocketFixture.thread),
                turnID: "turn-2", mode: mode, text: "literal original-thread text")
            let result = await channel.send(request)
            XCTAssertEqual(result, .accepted)
        }
        let writes = fixture.requests.filter { ["thread/queue/add", "turn/steer"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(writes.count, 2)
        for write in writes { XCTAssertEqual((write["params"] as? [String: Any])?["threadId"] as? String, DaemonSocketFixture.thread) }
        XCTAssertEqual((writes.first?["params"] as? [String: Any])?["expectedTurnId"] as? String, "turn-2")
        XCTAssertFalse(fixture.requests.contains { ["thread/start", "thread/fork", "turn/start"].contains($0["method"] as? String ?? "") })
    }

    @MainActor func testNativeMessageMismatchedOrLostAcknowledgementsNeverClaimAcceptanceOrRetry() async throws {
        for (outcome, mode) in [(DaemonSocketFixture.Outcome.queueWrongClient, AgentMessageMode.queue),
                                (.queueMissingID, .queue), (.queueLostACK, .queue), (.steerWrongTurn, .steer)] {
            let fixture = try DaemonSocketFixture(outcome)
            defer { fixture.stop() }
            let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
            defer { channel.stop() }
            var latest: CodexPrimarySnapshot?
            channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { latest = value } }
            try await NativeUI.waitFor("original owner can accept the action") { latest?.capabilities.contains(mode.capability) == true }
            let request = AgentMessageRequest(id: UUID(), sessionID: CodexAgentState.id(DaemonSocketFixture.thread),
                turnID: "turn-2", mode: mode, text: "original message must remain unconfirmed")
            let result = await channel.send(request)
            XCTAssertEqual(result, .uncertain, "\(outcome)")
            let writes = fixture.requests.filter { ["thread/queue/add", "turn/steer"].contains($0["method"] as? String ?? "") }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual((writes.first?["params"] as? [String: Any])?["clientUserMessageId"] as? String, request.id.uuidString)
            XCTAssertFalse(fixture.requests.contains { ["thread/start", "thread/fork", "turn/start"].contains($0["method"] as? String ?? "") })
        }
    }

    @MainActor func testChildSubscriptionRequiresVerifiedParentAndNeverAttachesForeignRoot() async throws {
        let fixture = try DaemonSocketFixture(.children)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        defer { channel.stop() }
        var snapshots: [String: CodexPrimarySnapshot] = [:]
        channel.start(threads: [DaemonSocketFixture.thread]) { if case .snapshot(let value) = $0 { snapshots[value.threadID] = value } }
        try await NativeUI.waitFor("root and its child attached") { snapshots.count == 2 }
        XCTAssertEqual(snapshots[DaemonSocketFixture.child]?.classification, .subagent)
        XCTAssertEqual(snapshots[DaemonSocketFixture.child]?.parentThreadID, DaemonSocketFixture.thread)
        XCTAssertFalse(snapshots[DaemonSocketFixture.child]?.capabilities.contains(.send) ?? true)
        let attached = fixture.requests.filter { $0["method"] as? String == "thread/resume" }.compactMap { ($0["params"] as? [String: Any])?["threadId"] as? String }
        XCTAssertEqual(Set(attached), [DaemonSocketFixture.thread, DaemonSocketFixture.child])
        channel.updateThreads([])
        try await NativeUI.waitFor("both subscriptions released") { fixture.requests.filter { $0["method"] as? String == "thread/unsubscribe" }.count == 2 }
    }

    func testOwnedDaemonSymlinkAcceptsOnlyPrivateSocketAndDirectories() throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let resolved = try XCTUnwrap(CodexDaemonConnection.ownedSocket(fixture.advertised))
        var expected = stat(), actual = stat()
        XCTAssertEqual(lstat(fixture.physical, &expected), 0)
        XCTAssertEqual(lstat(resolved, &actual), 0)
        XCTAssertEqual(expected.st_ino, actual.st_ino)
        XCTAssertEqual(chmod(fixture.physical, 0o666), 0)
        XCTAssertNil(CodexDaemonConnection.ownedSocket(fixture.advertised))
        XCTAssertEqual(chmod(fixture.physical, 0o600), 0)
        XCTAssertEqual(chmod(fixture.root.path, 0o777), 0)
        XCTAssertNil(CodexDaemonConnection.ownedSocket(fixture.advertised))
        XCTAssertEqual(chmod(fixture.root.path, 0o700), 0)
    }

    func testUpgradeFragmentationPingAndExactLoadedThreadRead() async throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        defer { connection.cancel() }
        let loaded = try await connection.request(method: "thread/loaded/list", params: [:])
        XCTAssertEqual(loaded["data"] as? [String], [DaemonSocketFixture.thread])
        let metadata = try await connection.request(method: "thread/read", params: ["threadId": DaemonSocketFixture.thread, "includeTurns": false])
        XCTAssertEqual((metadata["thread"] as? [String: Any])?["id"] as? String, DaemonSocketFixture.thread)
        XCTAssertEqual(fixture.requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/loaded/list", "thread/read"])
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread/resume" })
    }

    func testOptionalQueueRejectionKeepsExistingSubscriptionConnectionUsable() async throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        defer { connection.cancel() }
        do {
            _ = try await connection.request(method: "thread/queue/list", params: ["threadId": DaemonSocketFixture.thread, "limit": 1])
            XCTFail("unsupported queue probe accepted")
        } catch { XCTAssertEqual((error as? CodexDaemonConnection.Failure)?.code, -32601) }
        let loaded = try await connection.request(method: "thread/loaded/list", params: [:])
        XCTAssertEqual(loaded["data"] as? [String], [DaemonSocketFixture.thread])
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "initialize" }.count, 1)
    }

    func testInvalidUpgradeCannotInitializeOrSubmit() async throws {
        let fixture = try DaemonSocketFixture(.invalidUpgrade)
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        do { _ = try await connection.request(method: "turn/start", params: [:], mutation: true); XCTFail("invalid upgrade accepted") }
        catch { XCTAssertFalse((error as? CodexDaemonConnection.Failure)?.submitted ?? true) }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testExplicitControlTransactionPreservesExpectedVersionAndReload() async throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let params: [String: Any] = ["expectedVersion": "original", "reloadUserConfig": true,
                                    "edits": [["keyPath": "hooks.state.own", "value": false, "mergeStrategy": "replace"]]]
        let data = try await CodexDaemonControl.request(root: fixture.root, method: "config/batchWrite", params: JSONSerialization.data(withJSONObject: params))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String, "fixture-next-version")
        let sent = try XCTUnwrap(fixture.requests.last?["params"] as? [String: Any])
        XCTAssertEqual(sent["expectedVersion"] as? String, "original")
        XCTAssertEqual(sent["reloadUserConfig"] as? Bool, true)
        do { _ = try await CodexDaemonControl.request(root: fixture.root, method: "thread/resume", params: Data("{}".utf8)); XCTFail("resume must not be exposed by control API") }
        catch { XCTAssertEqual((error as? CodexDaemonConnection.Failure)?.code, -32600) }
    }

    func testDisconnectAfterSubmissionIsUnknownAndNeverReplayed() async throws {
        let fixture = try DaemonSocketFixture(.disconnectMutation)
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        do { _ = try await connection.request(method: "turn/steer", params: ["threadId": DaemonSocketFixture.thread, "expectedTurnId": "turn-1"], mutation: true); XCTFail("lost acknowledgement accepted") }
        catch { XCTAssertTrue((error as? CodexDaemonConnection.Failure)?.submitted ?? false) }
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "turn/steer" }.count, 1)
    }

    func testCancellationWakesPendingMutationWithUnknownDelivery() async throws {
        let submitted = expectation(description: "fixture received mutation")
        let fixture = try DaemonSocketFixture(.holdMutation, onMutation: { submitted.fulfill() })
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        let task = Task { try await connection.request(method: "turn/start", params: ["threadId": DaemonSocketFixture.thread], mutation: true) }
        await fulfillment(of: [submitted], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled send accepted") }
        catch { XCTAssertTrue((error as? CodexDaemonConnection.Failure)?.submitted ?? false) }
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    func testBoundedRequestTimeoutKeepsSubmittedMutationUnknown() async throws {
        let fixture = try DaemonSocketFixture(.holdMutation)
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised, timeout: 0.15)
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await connection.request(method: "turn/start", params: [:], mutation: true); XCTFail("request exceeded its deadline") }
        catch { XCTAssertTrue((error as? CodexDaemonConnection.Failure)?.submitted ?? false) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    func testOversizedServerFrameCannotAllocateOrSubmit() async throws {
        let fixture = try DaemonSocketFixture(.oversizedFrame)
        defer { fixture.stop() }
        let connection = CodexDaemonConnection(path: fixture.advertised)
        do { _ = try await connection.request(method: "turn/start", params: [:], mutation: true); XCTFail("oversized frame accepted") }
        catch { XCTAssertFalse((error as? CodexDaemonConnection.Failure)?.submitted ?? true) }
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "turn/start" })
    }

    func testMutationErrorsKeepInternalFailuresUncertainAndOnlyExplicitRejectionsDefinite() async throws {
        for code in [-32600, -32601, -32602, -32603, -32000] {
            let fixture = try DaemonSocketFixture(.rpcError(code))
            defer { fixture.stop() }
            let connection = CodexDaemonConnection(path: fixture.advertised)
            do { _ = try await connection.request(method: "turn/start", params: [:], mutation: true); XCTFail("error accepted") }
            catch {
                let failure = try XCTUnwrap(error as? CodexDaemonConnection.Failure)
                XCTAssertEqual(failure.code, code)
                XCTAssertEqual(failure.submitted, ![-32600, -32601, -32602].contains(code))
            }
            XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        }
    }

    @MainActor func testSnapshotsExcludeReasoningOutputsAndUnearnedCoverage() throws {
        let turn: [String: Any] = ["id": "turn-1", "status": "inProgress", "startedAt": 1_600_000_000, "items": [
            ["type": "userMessage", "content": [["type": "text", "text": "用户输入"]]],
            ["type": "reasoning", "text": "PRIVATE REASONING"],
            ["type": "commandExecution", "id": "tool-1", "status": "inProgress", "command": "swift test", "aggregatedOutput": "PRIVATE OUTPUT"],
            ["type": "agentMessage", "phase": "commentary", "text": "正在验证。"]]]
        var metadata = DaemonSocketFixture.metadata
        metadata["status"] = ["type": "active", "activeFlags": []]
        let snapshot = try XCTUnwrap(CodexDaemonChannel.normalize(thread: metadata, turn: turn))
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.turnID, "turn-1")
        XCTAssertEqual(snapshot.context.startedAt, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(snapshot.context.prompt, "用户输入")
        XCTAssertEqual(snapshot.context.progressText, "正在验证。")
        XCTAssertEqual(snapshot.context.toolDetail, "swift test")
        XCTAssertTrue(snapshot.capabilities.contains(.steer))
        XCTAssertFalse(snapshot.capabilities.contains(.send))
        XCTAssertTrue(snapshot.capabilities.intersection([.lifecycle, .tools, .messages, .progress, .plans, .questions, .approvals, .children]).isEmpty)
        XCTAssertNil(snapshot.approval); XCTAssertNil(snapshot.context.pendingInput)
        var withoutStart = turn
        withoutStart.removeValue(forKey: "startedAt")
        XCTAssertNil(CodexDaemonChannel.normalize(thread: metadata, turn: withoutStart)?.context.startedAt)
        metadata["status"] = ["type": "notLoaded"]
        XCTAssertNil(CodexDaemonChannel.normalize(thread: metadata, turn: turn))
    }

    @MainActor func testMissingDaemonRetriesBackOffAndNeverCreateAnEndpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nx-daemon-missing-" + UUID().uuidString)
        let channel = CodexDaemonChannel(root: root, interval: 0.05, timeout: 0.05)
        let failures = expectation(description: "three finite retry attempts")
        var observed: [TimeInterval] = []
        channel.start(threads: [DaemonSocketFixture.thread]) { update in
            if case .unavailable = update {
                observed.append(ProcessInfo.processInfo.systemUptime)
                if observed.count == 3 { failures.fulfill() }
            }
        }
        await fulfillment(of: [failures], timeout: 3)
        channel.stop()
        XCTAssertGreaterThanOrEqual(observed.count, 3)
        if observed.count >= 3 {
            XCTAssertGreaterThanOrEqual(observed[1] - observed[0], 0.09)
            XCTAssertGreaterThanOrEqual(observed[2] - observed[1], 0.18)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testUpstreamTimestampsAcceptFiniteNumbersButRejectBooleanAndStringCoercion() throws {
        let valid: [(Any, TimeInterval)] = [
            (1_600_000_000, 1_600_000_000),
            (1_600_000_000.25, 1_600_000_000.25),
            (NSNumber(value: Int64(1_600_000_000)), 1_600_000_000)
        ]
        for (number, seconds) in valid {
            var metadata = DaemonSocketFixture.metadata
            metadata["updatedAt"] = number
            let turn: [String: Any] = ["id": "turn-1", "status": "completed", "startedAt": number]
            let value = try XCTUnwrap(CodexDaemonChannel.normalize(thread: metadata, turn: turn))
            XCTAssertEqual(value.updatedAt, Date(timeIntervalSince1970: seconds))
            XCTAssertEqual(value.context.startedAt, Date(timeIntervalSince1970: seconds))
        }
        for invalid in [true, NSNumber(value: false), "1600000000", Double.infinity, Double.nan, NSNull()] as [Any] {
            var metadata = DaemonSocketFixture.metadata
            metadata["updatedAt"] = invalid
            let turn: [String: Any] = ["id": "turn-1", "status": "completed", "startedAt": invalid]
            let value = try XCTUnwrap(CodexDaemonChannel.normalize(thread: metadata, turn: turn))
            XCTAssertNil(value.updatedAt)
            XCTAssertNil(value.context.startedAt)
        }
    }

    @MainActor func testStopImmediatelyRemovesCapabilitiesAndCancelsFurtherReads() async throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 0.05)
        let first = expectation(description: "resident snapshot")
        var snapshots = 0, unavailable = 0
        channel.start(threads: [DaemonSocketFixture.thread]) { update in
            switch update {
            case .snapshot: snapshots += 1; if snapshots == 1 { first.fulfill() }
            case .unavailable: unavailable += 1
            }
        }
        await fulfillment(of: [first], timeout: 3)
        channel.stop()
        let stoppedCount = snapshots
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(snapshots, stoppedCount)
        XCTAssertGreaterThan(unavailable, 0)
        let attachments = fixture.requests.filter { $0["method"] as? String == "thread/resume" }
        XCTAssertEqual(attachments.count, 1)
        let params = try XCTUnwrap(attachments.first?["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["threadId", "excludeTurns"])
        XCTAssertEqual(params["threadId"] as? String, DaemonSocketFixture.thread)
        XCTAssertEqual(params["excludeTurns"] as? Bool, true)
    }

    @MainActor func testChannelSendsOnlyResidentOriginalThreadWithLiteralTextAndNoOverrides() async throws {
        let fixture = try DaemonSocketFixture()
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 1)
        defer { channel.stop() }
        let first = expectation(description: "verified resident sender")
        channel.start(threads: [DaemonSocketFixture.thread]) { update in
            if case .snapshot(let value) = update, value.capabilities.contains(.send) { first.fulfill() }
        }
        await fulfillment(of: [first], timeout: 3)
        let literal = "literal $(text) unchanged 第二行"
        let request = AgentMessageRequest(id: UUID(), sessionID: CodexAgentState.id(DaemonSocketFixture.thread), turnID: "turn-1", mode: .send, text: literal)
        let result = await channel.send(request)
        XCTAssertEqual(result, .accepted)
        let sends = fixture.requests.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(sends.count, 1)
        let params = try XCTUnwrap(sends.first?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, DaemonSocketFixture.thread)
        XCTAssertEqual((params["input"] as? [[String: Any]])?.first?["text"] as? String, literal)
        XCTAssertNil(params["model"]); XCTAssertNil(params["approvalPolicy"]); XCTAssertNil(params["sandboxPolicy"])
        XCTAssertFalse(fixture.requests.contains { ["thread/start", "thread/fork"].contains($0["method"] as? String ?? "") })
        let queued = AgentMessageRequest(id: UUID(), sessionID: request.sessionID, turnID: "turn-1", mode: .queue, text: literal)
        let queueResult = await channel.send(queued)
        XCTAssertEqual(queueResult, .failed)
    }

    @MainActor func testUnloadedThreadIsNeverResumedAndWrongResumeIdentityNeverEarnsCoverage() async throws {
        for outcome in [DaemonSocketFixture.Outcome.unloaded, .wrongResume] {
            let fixture = try DaemonSocketFixture(outcome)
            defer { fixture.stop() }
            let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
            let unavailable = expectation(description: "no verified subscription")
            var snapshots = 0, reported = false
            channel.start(threads: [DaemonSocketFixture.thread]) { update in
                if case .snapshot = update { snapshots += 1 }
                if case .unavailable = update, !reported { reported = true; unavailable.fulfill() }
            }
            await fulfillment(of: [unavailable], timeout: 3)
            channel.stop()
            XCTAssertEqual(snapshots, 0)
            if outcome == .unloaded { XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread/resume" }) }
        }
    }

    @MainActor func testUnmaterializedConversationWaitsForInputWithoutResumingOrResettingTheLink() async throws {
        let fixture = try DaemonSocketFixture(.unmaterialized)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 0.05)
        defer { channel.stop() }
        var snapshots = 0
        channel.start(threads: [DaemonSocketFixture.thread]) {
            if case .snapshot = $0 { snapshots += 1 }
        }
        try await NativeUI.waitFor("fresh thread rechecked on the same healthy connection") {
            fixture.requests.filter { $0["method"] as? String == "thread/turns/list" }.count >= 2
        }
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "thread/resume" })
        XCTAssertEqual(snapshots, 0)
    }

    @MainActor func testSubscribedEventsArriveWithoutPollingAndDisconnectRevokesCoverage() async throws {
        let fixture = try DaemonSocketFixture(.streamEvents)
        defer { fixture.stop() }
        let channel = CodexDaemonChannel(root: fixture.root, interval: 60)
        let ready = expectation(description: "subscription baseline")
        let tool = expectation(description: "tool start")
        let ended = expectation(description: "tool completion")
        let disconnected = expectation(description: "disconnect clears coverage")
        var baseline = false, sawTool = false, sawEnd = false, lost = false
        channel.start(threads: [DaemonSocketFixture.thread]) { update in
            switch update {
            case .snapshot(let snapshot):
                if !baseline, snapshot.capabilities.contains(.tools) { baseline = true; ready.fulfill() }
                if !sawTool, snapshot.activeToolID == "cmd-1" { sawTool = true; tool.fulfill() }
                if !sawEnd, snapshot.context.lastCompletedTool?.name == "exec_command" { sawEnd = true; ended.fulfill() }
            case .unavailable:
                if baseline && !lost { lost = true; disconnected.fulfill() }
            }
        }
        await fulfillment(of: [ready, tool, ended, disconnected], timeout: 4, enforceOrder: true)
        channel.stop()
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "thread/resume" }.count, 1)
        XCTAssertFalse(fixture.requests.contains { ["thread/start", "thread/fork"].contains($0["method"] as? String ?? "") })
    }
}
