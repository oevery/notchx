import Darwin
import Foundation
import XCTest
@testable import NotchX

private enum DesktopStatusFixtures {
    static let thread = AgentFixtures.thread
    static let owner = "status-fixture-owner"
    static func state(active: Bool = true, items: [[String: Any]]? = nil) -> [String: Any] {
        ["id": thread, "hostId": "local", "parentThreadId": NSNull(), "threadSource": "user",
         "title": "Fixture task", "cwd": "/fixture/work", "gitInfo": ["branch": "main"],
         "latestModel": "fixture-model", "updatedAt": 1_700_000_000_000, "resumeState": "resumed",
         "threadRuntimeStatus": ["type": active ? "active" : "idle", "activeFlags": []],
         "requests": [], "turns": [["turnId": "fixture-turn", "status": active ? "inProgress" : "completed",
          "turnStartedAtMs": 1_700_000_000_000, "items": items ?? [
            ["id": "prompt", "type": "userMessage", "content": [["type": "text", "text": "Inspect the source"]]],
            ["id": "cmd", "type": "commandExecution", "command": "swift --version", "status": active ? "inProgress" : "completed", "aggregatedOutput": "PRIVATE_TOOL_OUTPUT"]
          ]]]]
    }
    static func message(_ change: [String: Any], owner: String = owner, thread: String = thread) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": owner, "version": 11,
         "params": ["conversationId": thread, "hostId": "local", "change": change]]
    }
    static func snapshot(_ state: [String: Any] = state(), revision: Int64 = 1) -> [String: Any] {
        message(["type": "snapshot", "revision": revision, "conversationState": state])
    }
    static func patches(_ patches: [[String: Any]], base: Int64, revision: Int64) -> [String: Any] {
        message(["type": "patches", "baseRevision": base, "revision": revision, "patches": patches])
    }
    static func decoded(_ result: CodexDesktopStreamResult, file: StaticString = #filePath, line: UInt = #line) throws -> CodexPrimarySnapshot {
        guard case .snapshot(let value) = result else { XCTFail("Expected a validated snapshot", file: file, line: line); throw AgentHookWireError.invalidMessage }
        return value
    }
}

/// Real socket fixture for lifecycle/cancellation boundaries; the state
/// accumulator itself is real in these tests, not replaced by a fake reducer.
private final class DesktopStatusSocket: @unchecked Sendable {
    enum Mode { case steady, gap, disconnectOnce, largeSnapshot, oversizedFrame }
    let root: URL
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var client: Int32?
    private var methods: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return methods }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    init(_ mode: Mode = .steady) throws {
        root = try AgentFixtures.directory()
        let path = root.appendingPathComponent("ipc/ipc.sock").path
        try AgentUnixSocket.prepareDirectory(for: path)
        listener = try AgentUnixSocket.descriptor()
        var address = try AgentUnixSocket.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { close(listener); throw AgentHookWireError.unavailable }
        DispatchQueue.global(qos: .utility).async { self.serve(mode) }
    }
    func stop() {
        lock.lock(); stopped = true
        if let client { _ = shutdown(client, SHUT_RDWR) }
        _ = shutdown(listener, SHUT_RDWR); lock.unlock()
    }
    private func serve(_ mode: Mode) {
        defer { close(listener); try? FileManager.default.removeItem(at: root) }
        var connection = 0
        while !isStopped {
            do {
                try AgentUnixSocket.wait(listener, events: Int16(POLLIN), until: ProcessInfo.processInfo.systemUptime + 4)
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { continue }
                lock.lock(); client = fd; lock.unlock()
                var enabled: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                connection += 1
                do { try serve(fd, mode: mode, connection: connection) } catch { /* Closed/cancelled fixture clients are expected. */ }
                lock.lock(); client = nil; lock.unlock(); close(fd)
            } catch { if isStopped { return } }
        }
    }
    private func serve(_ fd: Int32, mode: Mode, connection: Int) throws {
        func read(_ count: Int) throws -> Data {
            var bytes = Data()
            while bytes.count < count {
                try AgentUnixSocket.wait(fd, events: Int16(POLLIN), until: ProcessInfo.processInfo.systemUptime + 4)
                var buffer = [UInt8](repeating: 0, count: count - bytes.count)
                let size = Darwin.read(fd, &buffer, buffer.count)
                guard size > 0 else { throw AgentHookWireError.unavailable }
                bytes.append(contentsOf: buffer.prefix(size))
            }
            return bytes
        }
        func send(_ object: [String: Any]) throws {
            let payload = try JSONSerialization.data(withJSONObject: object)
            var length = UInt32(payload.count).littleEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(payload)
            // Fragment the length prefix to exercise actual stream framing.
            try AgentUnixSocket.write(Data(frame.prefix(2)), to: fd, until: ProcessInfo.processInfo.systemUptime + 2)
            try AgentUnixSocket.write(Data(frame.dropFirst(2)), to: fd, until: ProcessInfo.processInfo.systemUptime + 2)
        }
        var followingCount = 0
        while !isStopped {
            let header = try read(4), length = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length > 0, length < 64 * 1024, let object = try JSONSerialization.jsonObject(with: read(length)) as? [String: Any],
                  let method = object["method"] as? String else { throw AgentHookWireError.invalidMessage }
            if object["type"] as? String == "request" {
                lock.lock(); methods.append(method); lock.unlock()
                var response: [String: Any] = ["type": "response", "requestId": object["requestId"]!, "method": method,
                    "resultType": "success", "handledByClientId": DesktopStatusFixtures.owner]
                switch method {
                case "initialize": response["result"] = ["clientId": "status-client-" + String(connection)]
                case "thread-owner-discovery": response["result"] = ["supportsUntrustedAppInput": true]
                case "thread-follower-read-model-settings": response["result"] = ["settings": ["resumeState": "resumed", "model": "fixture-model"]]
                default: throw AgentHookWireError.invalidMessage
                }
                try send(response)
            } else if method == "thread-stream-following-changed",
                      (object["params"] as? [String: Any])?["following"] as? Bool == true {
                followingCount += 1
                if mode == .oversizedFrame {
                    var length = UInt32(CodexDesktopWire.maximumIncomingFrameBytes + 1).littleEndian
                    try withUnsafeBytes(of: &length) { try AgentUnixSocket.write(Data($0), to: fd, until: ProcessInfo.processInfo.systemUptime + 2) }
                    continue
                }
                let revision: Int64 = followingCount == 1 ? Int64(connection) : 11
                var document = DesktopStatusFixtures.state()
                if mode == .largeSnapshot { document["unusedHistory"] = String(repeating: "x", count: 5 * 1024 * 1024) }
                try send(DesktopStatusFixtures.snapshot(document, revision: revision))
                if mode == .disconnectOnce, connection == 1 { return }
                if mode == .gap, followingCount == 1 {
                    try send(DesktopStatusFixtures.patches([], base: 9, revision: 10))
                }
            }
        }
    }
}

final class CodexDesktopStatusChannelTests: XCTestCase {
    func testOptimisticNullTurnIDRetainsRevisionUntilOwnerAcknowledgesNewTurn() throws {
        var document = DesktopStatusFixtures.state(active: false)
        let previous = try XCTUnwrap((document["turns"] as? [[String: Any]])?.first)
        document["turns"] = [[String: Any]]()
        document["turnHistory"] = ["kind": "canonical", "history": [
            "entitiesByKey": ["previous": previous], "islands": [["entries": [["value": "previous"]]]]]]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        let prefix: [Any] = ["turnHistory", "history", "entitiesByKey", "optimistic"]
        let pending = stream.consume(DesktopStatusFixtures.patches([
            ["op": "add", "path": prefix, "value": ["turnId": NSNull(), "status": "inProgress", "items": []]],
            ["op": "add", "path": ["turnHistory", "history", "islands", 0, "entries", 1], "value": ["value": "optimistic"]],
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active", "activeFlags": []]]
        ], base: 1, revision: 2))
        let transition = try DesktopStatusFixtures.decoded(pending)
        XCTAssertNil(transition.turnID); XCTAssertTrue(transition.capabilities.isEmpty)
        XCTAssertNil(transition.context.prompt); XCTAssertNil(transition.context.latestActivity)
        XCTAssertEqual(stream.revision, 2, "Do not restart the subscription for a known optimistic placeholder")
        let started = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": prefix + ["turnId"], "value": "new-original-turn"],
            ["op": "add", "path": prefix + ["items", 0], "value": ["id": "cmd-new", "type": "commandExecution", "status": "inProgress", "command": "fixture command"]]
        ], base: 2, revision: 3)))
        XCTAssertEqual(started.turnID, "new-original-turn"); XCTAssertEqual(started.status, .running)
        XCTAssertTrue(started.capabilities.contains([.steer, .queue])); XCTAssertEqual(started.activeToolName, "exec_command")
        XCTAssertEqual(stream.revision, 3)
        let finishing = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]
        ], base: 3, revision: 4)))
        XCTAssertNil(finishing.turnID); XCTAssertTrue(finishing.capabilities.isEmpty)
        XCTAssertNil(finishing.context.latestActivity)
        let complete = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": prefix + ["status"], "value": "completed"]
        ], base: 4, revision: 5)))
        XCTAssertEqual(complete.status, .completed); XCTAssertTrue(complete.capabilities.contains(.send))
        XCTAssertEqual(complete.turnID, "new-original-turn"); XCTAssertEqual(stream.revision, 5)
    }
    func testLargeHistoryRetainsRecentTurnsAndPatchesOriginalIndicesWithoutRefilteringHistory() throws {
        var document = DesktopStatusFixtures.state()
        let latest = try XCTUnwrap((document["turns"] as? [[String: Any]])?.first)
        var history: [[String: Any]] = (0..<300).map { index in
            var turn = latest; turn["turnId"] = "old-\(index)"
            turn["items"] = [["type": "agentMessage", "id": "old-message-\(index)", "phase": "commentary", "text": String(repeating: "OLD_PRIVATE_BODY", count: 1500)]]
            return turn
        }
        history.append(latest); document["turns"] = history
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let first = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        XCTAssertEqual(first.activeToolID, "cmd")
        XCTAssertLessThan(stream.retainedBytes, 40_000)
        XCTAssertLessThan(stream.filteredNodeCount, 1000)
        let changed = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "OLD_CHANGED_BODY"],
            ["op": "remove", "path": ["turns", 0]],
            ["op": "replace", "path": ["turns", 299, "items", 1, "status"], "value": "completed"]
        ], base: 1, revision: 2)))
        XCTAssertNil(changed.activeToolID)
        XCTAssertEqual(changed.context.latestActivity, .completedTool(name: "exec_command", detail: "swift --version"))
        XCTAssertLessThan(stream.filteredNodeCount, 100, "One item update must not filter all history again")
        XCTAssertFalse(String(decoding: try AgentFixtures.json(XCTUnwrap(stream.document)), as: UTF8.self).contains("OLD_"))
    }

    func testCanonicalAppendReorderingAndPromotionOfDiscardedTurnRecoverSafely() throws {
        var document = DesktopStatusFixtures.state()
        let latest = try XCTUnwrap((document["turns"] as? [[String: Any]])?.first)
        var a = latest; a["turnId"] = "older-a"
        var b = latest; b["turnId"] = "older-b"
        document["turns"] = []
        document["turnHistory"] = ["kind": "canonical", "history": ["entitiesByKey": ["a": a, "b": b, "latest": latest],
            "islands": [["entries": [["value": "a"], ["value": "b"], ["value": "latest"]]]]]]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        var new = latest; new["turnId"] = "new-turn"
        let next = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "add", "path": ["turnHistory", "history", "entitiesByKey", "new"], "value": new],
            ["op": "add", "path": ["turnHistory", "history", "islands", 0, "entries", 3], "value": ["value": "new"]]
        ], base: 1, revision: 2)))
        XCTAssertEqual(next.turnID, "new-turn")
        if case .resubscribe = stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": ["turnHistory", "history", "islands", 0, "entries"], "value": [["value": "a"]]]
        ], base: 2, revision: 3)) {} else { XCTFail("Discarded old content cannot become current evidence") }
        XCTAssertNil(stream.document)
        XCTAssertEqual(try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document, revision: 4))).turnID, "fixture-turn")
    }

    func testOutputDescendantPatchesAndPublicToPrivateTransitionsDoNotRetainSecrets() throws {
        var document = DesktopStatusFixtures.state()
        var turns = try XCTUnwrap(document["turns"] as? [[String: Any]])
        var items = try XCTUnwrap(turns[0]["items"] as? [[String: Any]])
        items.append(["id": "public", "type": "agentMessage", "phase": "commentary", "text": "Previously public"])
        items[1]["aggregatedOutput"] = ["nested": ["type": "agentMessage", "phase": "commentary", "text": "PRIVATE_INITIAL"]]
        turns[0]["items"] = items; document["turns"] = turns
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        let next = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": ["turns", 0, "items", 1, "aggregatedOutput", "nested", "text"], "value": "PRIVATE_PATCH"],
            ["op": "replace", "path": ["turns", 0, "items", 2, "phase"], "value": "final_answer"],
            ["op": "replace", "path": ["turns", 0, "items", 2, "text"], "value": "PRIVATE_FINAL"]
        ], base: 1, revision: 2)))
        XCTAssertNil(next.context.progressText)
        let cached = String(decoding: try AgentFixtures.json(XCTUnwrap(stream.document)), as: UTF8.self)
        XCTAssertFalse(cached.contains("PRIVATE_")); XCTAssertFalse(cached.contains("Previously public"))
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document, revision: 3)))
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches([
            ["op": "replace", "path": ["turns", 0, "items", 2, "phase"], "value": "final_answer"],
            ["op": "remove", "path": ["turns", 0, "items", 0]]
        ], base: 3, revision: 4)))
        XCTAssertFalse(String(decoding: try AgentFixtures.json(XCTUnwrap(stream.document)), as: UTF8.self).contains("Previously public"),
            "Visibility redaction must happen before a following array removal changes item indices")
    }

    @MainActor func testLargeSnapshotTraversesActualSocketAndOversizedLengthIsRejected() async throws {
        XCTAssertFalse(CodexDesktopWire.acceptsIncomingFrame(0))
        XCTAssertTrue(CodexDesktopWire.acceptsIncomingFrame(10_352_292))
        XCTAssertFalse(CodexDesktopWire.acceptsIncomingFrame(CodexDesktopWire.maximumIncomingFrameBytes + 1))
        let fixture = try DesktopStatusSocket(.largeSnapshot); defer { fixture.stop() }
        let channel = CodexDesktopStatusChannel(root: fixture.root)
        let received = expectation(description: "Snapshot larger than old 4 MiB cap")
        channel.start(threads: [DesktopStatusFixtures.thread]) { update in
            if case .snapshot(let value) = update { XCTAssertEqual(value.activeToolID, "cmd"); received.fulfill() }
        }
        await fulfillment(of: [received], timeout: 6); channel.stop()
        let tooLarge = try DesktopStatusSocket(.oversizedFrame); defer { tooLarge.stop() }
        let rejected = CodexDesktopStatusChannel(root: tooLarge.root)
        let withdrawn = expectation(description: "Oversized header withdraws unverified subscription")
        rejected.start(threads: [DesktopStatusFixtures.thread]) { update in
            if case .snapshot = update { XCTFail("Oversized header must not establish coverage") }
            if case .unavailable = update { withdrawn.fulfill() }
        }
        await fulfillment(of: [withdrawn], timeout: 3); rejected.stop()
    }

    func testSnapshotProjectsPublicContextWithoutReasoningFinalReplyOrToolOutput() throws {
        var document = DesktopStatusFixtures.state()
        var turn = try XCTUnwrap((document["turns"] as? [[String: Any]])?.first)
        var items = try XCTUnwrap(turn["items"] as? [[String: Any]])
        items.append(["id": "reason", "type": "reasoning", "summary": [["type": "text", "text": "PRIVATE_REASONING"]]])
        items.append(["id": "public", "type": "agentMessage", "phase": "commentary", "text": "Checking the implementation"])
        items.append(["id": "final", "type": "agentMessage", "phase": "final_answer", "text": "PRIVATE_FINAL_REPLY"])
        turn["items"] = items; document["turns"] = [turn]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let result = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        XCTAssertEqual(result.status, .running)
        XCTAssertEqual(result.context.prompt, "Inspect the source")
        XCTAssertEqual(result.context.model, "fixture-model")
        XCTAssertEqual(result.context.branch, "main")
        XCTAssertEqual(result.context.progressText, "Checking the implementation")
        XCTAssertEqual(result.activeToolName, "exec_command")
        XCTAssertEqual(result.context.toolDetail, "swift --version")
        XCTAssertFalse(result.capabilities.contains(.approvals))
        XCTAssertFalse(result.capabilities.contains(.questions))
        XCTAssertTrue(result.capabilities.contains([.steer, .queue]))
        let cached = String(decoding: try AgentFixtures.json(XCTUnwrap(stream.document)), as: UTF8.self)
        XCTAssertFalse(cached.contains("PRIVATE_"))
    }

    func testStrictRevisionsIgnoreDuplicatesAndRequireSnapshotAfterGapOrMalformedPatch() throws {
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot()))
        let finish: [[String: Any]] = [["op": "replace", "path": ["turns", 0, "items", 1, "status"], "value": "completed"]]
        let result = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches(finish, base: 1, revision: 2)))
        XCTAssertNil(result.activeToolID)
        XCTAssertEqual(result.context.latestActivity, .completedTool(name: "exec_command", detail: "swift --version"))
        if case .ignored = stream.consume(DesktopStatusFixtures.patches(finish, base: 1, revision: 2)) {} else { XCTFail("Duplicate must not replay") }
        if case .resubscribe = stream.consume(DesktopStatusFixtures.patches([], base: 8, revision: 9)) {} else { XCTFail("Gap needs snapshot") }
        XCTAssertNil(stream.document)
        if case .resubscribe = stream.consume(DesktopStatusFixtures.patches([], base: 9, revision: 10)) {} else { XCTFail("Patch cannot restore coverage") }
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(revision: 11)))
        let invalid: [[String: Any]] = [["op": "remove", "path": ["turns", 4000]]]
        if case .resubscribe = stream.consume(DesktopStatusFixtures.patches(invalid, base: 11, revision: 12)) {} else { XCTFail("Bad path needs snapshot") }
    }

    func testCanonicalOrderAndChildParentProofAreNotDictionaryOrderOrActivityInference() throws {
        var document = DesktopStatusFixtures.state(active: false)
        let last = try XCTUnwrap((document["turns"] as? [[String: Any]])?.first)
        var old = last; old["turnId"] = "old-turn"; old["status"] = "failed"
        document["turns"] = []
        document["turnHistory"] = ["kind": "canonical", "history": ["entitiesByKey": ["z-old": old, "a-new": last],
            "islands": [["entries": [["value": "z-old"], ["value": "a-new"]]]]]]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let result = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        XCTAssertEqual(result.turnID, "fixture-turn")
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(result.capabilities.contains(.send))
        var child = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner, expectedParent: AgentFixtures.other)
        if case .resubscribe = child.consume(DesktopStatusFixtures.snapshot(document)) {} else { XCTFail("Candidate alone cannot prove parent") }
        document["parentThreadId"] = AgentFixtures.other; document["threadSource"] = "subagent"
        let proven = try DesktopStatusFixtures.decoded(child.consume(DesktopStatusFixtures.snapshot(document, revision: 2)))
        XCTAssertEqual(proven.parentThreadID, AgentFixtures.other)
        XCTAssertEqual(proven.classification, .subagent)
        XCTAssertFalse(proven.capabilities.contains(.children))
    }

    func testQuestionObservationDoesNotClaimUnverifiedResponseOrApprovalCoverage() throws {
        var document = DesktopStatusFixtures.state()
        document["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnUserInput"]]
        document["requests"] = [["id": 141, "method": "item/tool/requestUserInput",
            "params": ["threadId": DesktopStatusFixtures.thread, "turnId": "fixture-turn",
                "questions": [["id": "choice", "question": "Which option?", "options": [["label": "A"]]]]]]]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let result = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(document)))
        XCTAssertEqual(result.status, .waitingInput)
        XCTAssertEqual(result.context.pendingInput, AgentPendingInput(id: "141", text: "Which option?", asynchronous: false))
        XCTAssertFalse(result.capabilities.contains(.questions))
        XCTAssertFalse(result.capabilities.contains(.approvals))
        XCTAssertFalse(result.capabilities.contains(.send))
    }

    func testKnownPlanAndOutputOnlyPatchesPreserveStructureWithoutLeakingText() throws {
        let items: [[String: Any]] = [
            ["id": "cmd", "type": "commandExecution", "command": "swift --version", "status": "completed",
             "output": [["type": "userMessage", "content": [["type": "text", "text": "PRIVATE_NESTED_OUTPUT"]]]]],
            ["id": "plan", "type": "todo-list", "plan": [["step": "Verify", "status": "inProgress"]]]
        ]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let first = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(DesktopStatusFixtures.state(items: items))))
        XCTAssertEqual(first.context.plan, [AgentPlanStep(step: "Verify", status: "in_progress")])
        XCTAssertTrue(first.capabilities.contains(.plans))
        let patch: [[String: Any]] = [["op": "replace", "path": ["turns", 0, "items", 0, "output", 0, "content", 0, "text"], "value": "PRIVATE_PATCH_OUTPUT"]]
        _ = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.patches(patch, base: 1, revision: 2)))
        let cached = String(decoding: try AgentFixtures.json(XCTUnwrap(stream.document)), as: UTF8.self)
        XCTAssertFalse(cached.contains("PRIVATE_"))
        XCTAssertEqual(stream.revision, 2)
    }

    func testStatuslessDesktopWebSearchHistoryDoesNotRejectOtherwiseValidCurrentTurn() throws {
        let items: [[String: Any]] = [
            ["type": "webSearch", "id": "search-one", "query": "Swift documentation",
             "action": ["type": "search", "query": "Swift documentation", "queries": ["Swift documentation"]], "results": NSNull()],
            ["type": "webSearch", "id": "open-one", "query": "",
             "action": ["type": "openPage", "url": "https://example.invalid"], "results": NSNull()],
            ["type": "commandExecution", "id": "current-command", "command": "swift --version", "status": "inProgress"]
        ]
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        let snapshot = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(DesktopStatusFixtures.state(items: items))))
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.activeToolID, "current-command")
        XCTAssertTrue(snapshot.capabilities.contains(.lifecycle))
        XCTAssertTrue(snapshot.capabilities.contains(.progress))
        XCTAssertFalse(snapshot.capabilities.contains(.tools), "Statusless history cannot replace tool-boundary hooks")
        XCTAssertNil(snapshot.context.lastCompletedTool, "Do not infer a completed search")
    }

    func testUnknownVersionSourceAndNewActivityDoNotClaimFullCoverage() throws {
        var stream = CodexDesktopStreamState(thread: DesktopStatusFixtures.thread, owner: DesktopStatusFixtures.owner)
        var foreign = DesktopStatusFixtures.snapshot(); foreign["sourceClientId"] = "other-owner"
        if case .ignored = stream.consume(foreign) {} else { XCTFail("Wrong owner must be ignored") }
        var wrong = DesktopStatusFixtures.snapshot(); wrong["version"] = 12
        if case .resubscribe = stream.consume(wrong) {} else { XCTFail("Unknown protocol version must revoke") }
        let unknown = DesktopStatusFixtures.state(items: [["id": "future", "type": "futureActivity", "output": "PRIVATE_OUTPUT"]])
        let result = try DesktopStatusFixtures.decoded(stream.consume(DesktopStatusFixtures.snapshot(unknown)))
        XCTAssertEqual(result.capabilities, [.lifecycle, .steer, .queue])
        XCTAssertNil(result.context.latestActivity)
    }

    @MainActor func testSocketGapRevokesThenRecoversAndStopRejectsQueuedCallbacks() async throws {
        let fixture = try DesktopStatusSocket(.gap); defer { fixture.stop() }
        let channel = CodexDesktopStatusChannel(root: fixture.root)
        let initial = expectation(description: "initial state"), withdrawn = expectation(description: "gap withdrawn"), recovered = expectation(description: "new snapshot")
        var revisions: [Int64] = [], losses = 0
        channel.start(threads: [DesktopStatusFixtures.thread]) { update in
            switch update {
            case .snapshot(let snapshot):
                revisions.append(snapshot.revision ?? -1)
                if snapshot.revision == 1 { initial.fulfill() }
                if snapshot.revision == 11 { recovered.fulfill() }
            case .unavailable(_, let ids):
                if ids.contains(DesktopStatusFixtures.thread) { losses += 1; if losses == 1 { withdrawn.fulfill() } }
            }
        }
        await fulfillment(of: [initial, withdrawn, recovered], timeout: 4)
        channel.stop(); let count = revisions.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(revisions.count, count, "Late worker callbacks must not recover stopped coverage")
        XCTAssertTrue(Set(fixture.requests).isSubset(of: ["initialize", "thread-owner-discovery", "thread-follower-read-model-settings"]))
    }

    @MainActor func testDisconnectRevokesCoverageBeforeReconnectAndThreadRemovalUnsubscribes() async throws {
        let fixture = try DesktopStatusSocket(.disconnectOnce); defer { fixture.stop() }
        let channel = CodexDesktopStatusChannel(root: fixture.root)
        let recovered = expectation(description: "reconnected snapshot")
        var revisions: [Int64] = [], losses = 0
        channel.start(threads: [DesktopStatusFixtures.thread]) { update in
            switch update {
            case .snapshot(let snapshot):
                revisions.append(snapshot.revision ?? -1)
                if snapshot.revision == 2 { recovered.fulfill() }
            case .unavailable(_, let ids): if ids.contains(DesktopStatusFixtures.thread) { losses += 1 }
            }
        }
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertEqual(Array(revisions.prefix(2)), [1, 2])
        XCTAssertGreaterThanOrEqual(losses, 1)
        channel.updateThreads([])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThanOrEqual(losses, 2)
        let request = AgentMessageRequest(id: UUID(), sessionID: CodexAgentState.id(DesktopStatusFixtures.thread), turnID: "fixture-turn", mode: .steer, text: "No mutation")
        let result = await channel.send(request)
        XCTAssertEqual(result, .failed)
        channel.stop()
    }

    func testReadonlyProtocolShapesRejectWrongOwnerAndNeverUseBuildIdentity() {
        let initialized: [String: Any] = ["resultType": "success", "method": "initialize", "result": ["clientId": "future-desktop-client"]]
        XCTAssertEqual(CodexDesktopWire.clientID(initialized), "future-desktop-client")
        var malformed = initialized
        malformed["result"] = ["clientId": "status-client-(connection)"]
        XCTAssertNil(CodexDesktopWire.clientID(malformed), "Parenthesized fixture text is not a valid initialized identity")
        let settings: [String: Any] = ["resultType": "success", "method": "thread-follower-read-model-settings",
            "handledByClientId": "owner", "result": ["settings": ["resumeState": "resumed", "model": "future-model"]]]
        XCTAssertTrue(CodexDesktopWire.validSettings(settings, owner: "owner"))
        XCTAssertFalse(CodexDesktopWire.validSettings(settings, owner: "different-owner"))
        XCTAssertNil(CodexDesktopProjection.integer(true))
        XCTAssertNil(CodexDesktopProjection.integer(1.5))
    }
}
