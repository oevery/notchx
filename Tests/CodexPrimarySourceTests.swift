import Foundation
import SQLite3
import XCTest
@testable import NotchX

@MainActor
private final class PrimarySourceFixture: CodexPrimaryChannel {
    let kind: CodexPrimaryChannelKind
    init(kind: CodexPrimaryChannelKind = .desktop) { self.kind = kind }
    var messages: [AgentMessageRequest] = []
    var decisions: [String] = []
    var receive: (@MainActor (CodexPrimaryChannelUpdate) -> Void)?
    var stopped = false
    var starts = 0
    var answers: [AgentInputResponse] = []
    var delivery = AgentMessageDelivery.accepted
    var threads: Set<String> = []
    func start(threads: Set<String>, receive: @escaping @MainActor (CodexPrimaryChannelUpdate) -> Void) { self.receive = receive; stopped = false; starts += 1 }
    func updateThreads(_ threads: Set<String>) { self.threads = threads }
    func stop() { stopped = true }
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery { messages.append(request); return delivery }
    func respondToInput(_ response: AgentInputResponse) async -> AgentMessageDelivery { answers.append(response); return .accepted }
    func respond(approval: AgentApproval, decision: AgentHookDecision) async -> AgentMessageDelivery {
        decisions.append(approval.id); return .accepted
    }
}

@MainActor
final class CodexPrimarySourceTests: XCTestCase {
    func testCatalogueOnlyProvidesCandidatesAndCannotRestoreDisconnectedCards() async throws {
        let root = try AgentFixtures.directory(), primary = PrimarySourceFixture()
        let directory = root.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("codex-dev.db").path, &db), SQLITE_OK)
        let sql = "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, source_kind TEXT, thread_source TEXT, source_updated_at REAL, display_title TEXT, missing_candidate INTEGER); INSERT INTO local_thread_catalog VALUES ('local','" + AgentFixtures.thread + "','vscode','user',1700000000,'Fixture candidate',0);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let source = CodexLiveStatusSource(root: root, socketPath: root.appendingPathComponent("unused.sock").path, channels: [primary])
        let manager = AgentManager(sourceFactory: { source })
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        manager.setEnabled(true)
        try await NativeUI.waitFor("catalogue candidate discovered") { primary.threads.contains(AgentFixtures.thread) }
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertNotEqual(manager.connection, .connected)
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: AgentFixtures.thread)
        snapshot.classification = .userSession; snapshot.status = .idle; snapshot.revision = 1
        primary.receive?(.snapshot(snapshot))
        XCTAssertEqual(manager.idleGroups.count, 1)
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("codex-dev.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE local_thread_catalog SET display_title = 'Renamed idle candidate', source_updated_at = 1700000002;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        source.refreshConnection()
        try await NativeUI.waitFor("catalogue title updated without overwriting native idle status") {
            manager.groups.first?.root.title == "Renamed idle candidate"
        }
        XCTAssertEqual(manager.idleGroups.first?.status, .idle)
        XCTAssertTrue(manager.activeGroups.isEmpty)
        snapshot.turnID = "turn-1"; snapshot.status = .running; snapshot.revision = 2
        primary.receive?(.snapshot(snapshot))
        XCTAssertEqual(manager.activeGroups.count, 1)
        snapshot.status = .completed; snapshot.revision = 3
        primary.receive?(.snapshot(snapshot))
        XCTAssertTrue(manager.activeGroups.isEmpty); XCTAssertEqual(manager.recentCompletedGroups.count, 1)
        primary.receive?(.unavailable(.desktop, [AgentFixtures.thread]))
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("codex-dev.db").path, &db), SQLITE_OK)
        let insert = "INSERT INTO local_thread_catalog VALUES ('local','" + AgentFixtures.other + "','vscode','user',1700000001,'New candidate',0);"
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        source.refreshConnection()
        try await NativeUI.waitFor("new catalogue candidate discovered") { primary.threads.contains(AgentFixtures.other) }
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertNotEqual(manager.connection, .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks.json").path))
    }

    func testFallbackRequiresOptInAndOnlyRunsAfterBothExistingOwnersWithdraw() async throws {
        let root = try AgentFixtures.directory(), desktop = PrimarySourceFixture(), daemon = PrimarySourceFixture(kind: .daemon)
        let path = root.appendingPathComponent("fallback.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path, channels: [desktop, daemon])
        let domain = "app.notchx.tests.fallback." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let manager = AgentManager(sourceFactory: { source }, preferenceStore: prefs)
        defer { manager.setEnabled(false); prefs.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(manager.codexHookFallbackEnabled)
        manager.setEnabled(true)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks.json").path))
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: AgentFixtures.thread, turnID: "turn-1")
        snapshot.classification = .userSession; snapshot.status = .running; snapshot.revision = 1
        snapshot.capabilities = [.lifecycle, .tools, .progress, .messages]
        desktop.receive?(.snapshot(snapshot))
        snapshot = CodexPrimarySnapshot(kind: .daemon, threadID: AgentFixtures.thread, turnID: "turn-1")
        snapshot.classification = .userSession; snapshot.status = .running; snapshot.revision = 1; snapshot.capabilities = [.lifecycle]
        daemon.receive?(.snapshot(snapshot))
        manager.setCodexHookFallbackEnabled(true)
        XCTAssertTrue(prefs.bool(forKey: AgentManager.codexHookFallbackKey))
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path), "Opt-in cannot start fallback over a healthy primary")
        desktop.receive?(.unavailable(.desktop, [AgentFixtures.thread]))
        XCTAssertEqual(manager.interaction.primaryChannels[CodexAgentState.id(AgentFixtures.thread)], .daemon)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
        daemon.receive?(.unavailable(.daemon, [AgentFixtures.thread]))
        XCTAssertTrue(AgentUnixSocket.ownedSocket(path))
        let envelope = AgentFixtures.approval()
        let pending = Task { try await Task.detached { try AgentUnixSocket.exchange(envelope, path: path, timeout: 5) }.value }
        try await NativeUI.waitFor("fallback request waits for a human decision") { manager.interaction.approvals.count == 1 }
        manager.setCodexHookFallbackEnabled(false)
        let reply = try await pending.value
        XCTAssertEqual(reply.decision, .deferToApp)
        XCTAssertTrue(manager.interaction.approvals.isEmpty)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
        XCTAssertFalse(manager.interaction.isListening)
        XCTAssertNotEqual(manager.connection, .connected, "An unavailable catalog cannot keep the stopped fallback connected")
        XCTAssertEqual(desktop.starts, 1); XCTAssertEqual(daemon.starts, 1)
        XCTAssertFalse(desktop.stopped || daemon.stopped, "Changing fallback must preserve primary subscriptions")
    }
    func testPrimaryHealthDoesNotDependOnTheCatalogueOrHookListener() async throws {
        let root = try AgentFixtures.directory(), primary = PrimarySourceFixture()
        let socket = root.appendingPathComponent("not-a-socket")
        let sentinel = Data("preserve existing file".utf8)
        try sentinel.write(to: socket)
        let source = CodexLiveStatusSource(root: root, socketPath: socket.path, channels: [primary])
        defer { source.stop(); try? FileManager.default.removeItem(at: root) }
        var connections: [AgentSourceConnection] = []
        var listening = true
        source.start { update in
            if case .connection(let value) = update { connections.append(value) }
            if case .interaction(let value) = update { listening = value.isListening }
        }
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: AgentFixtures.thread, turnID: "turn-1")
        snapshot.classification = .userSession; snapshot.status = .running; snapshot.revision = 1
        snapshot.capabilities = [.lifecycle, .progress]
        primary.receive?(.snapshot(snapshot))
        try await NativeUI.waitFor("catalogue failure observed after primary connection") { connections.count >= 3 }
        XCTAssertFalse(listening)
        XCTAssertEqual(connections.last, .connected, "A failed catalogue read must not hide a verified primary connection")
        XCTAssertEqual(try Data(contentsOf: socket), sentinel)
        primary.receive?(.unavailable(.desktop, [AgentFixtures.thread]))
        XCTAssertNotEqual(connections.last, .connected, "After primary withdrawal, report the actual fallback health")
    }

    func testOriginalNativeQuestionRemindsAndNavigatesWithoutSendingAnAnswer() async throws {
        let root = try AgentFixtures.directory(), primary = PrimarySourceFixture()
        let source = CodexLiveStatusSource(root: root, socketPath: root.appendingPathComponent("events.sock").path, channels: [primary])
        let manager = AgentManager(sourceFactory: { source })
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let id = CodexAgentState.id(AgentFixtures.thread)
        let question = AgentInputQuestion(id: "viewport", header: "Viewport", text: "Which viewport?", isSecret: false, options: [])
        let input = AgentPendingInput(id: "native-question", text: question.text, asynchronous: false, questions: [question], canRespond: true)
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: id.sessionID, turnID: "turn-1")
        snapshot.title = "Native question fixture"; snapshot.classification = .userSession
        snapshot.status = .waitingInput; snapshot.context.pendingInput = input; snapshot.revision = 1
        manager.setEnabled(true); primary.receive?(.snapshot(snapshot))
        XCTAssertEqual(manager.groups.first?.status, .waitingInput)
        XCTAssertEqual(manager.interaction.receivedEvents, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks.json").path))
        XCTAssertEqual(manager.panel.route, .detail(id))
        XCTAssertTrue(manager.attentionRequestID?.hasPrefix("input-") == true)
        XCTAssertEqual(manager.navigationTargets[id]?.desktopThreadID, AgentFixtures.thread)
        manager.refreshConnection()
        await NativeUI.drainMainQueue()
        XCTAssertTrue(primary.answers.isEmpty)
        XCTAssertTrue(primary.messages.isEmpty)
        primary.receive?(.unavailable(.desktop, [id.sessionID]))
        XCTAssertNil(manager.interaction.contexts[id]?.pendingInput)
        XCTAssertTrue(primary.answers.isEmpty)

    }

    func testBoundedSubscriptionsPreferActiveAndRecentChatsOverOldUUIDOrder() {
        let ids = (1...48).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let dates = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, Date(timeIntervalSince1970: Double($0.offset))) })
        let selected = CodexLiveStatusSource.primaryThreadSelection(known: Set(ids + ["invalid"]), dates: dates,
            active: [ids[0]], verified: [], limit: 32)
        XCTAssertEqual(selected.count, 32)
        XCTAssertTrue(selected.contains(ids[0]), "An old but active conversation must keep its subscription")
        XCTAssertTrue(selected.contains(ids[47]), "Newest conversations cannot lose to lexicographically older UUIDs")
        XCTAssertFalse(selected.contains(ids[1]))
        XCTAssertFalse(selected.contains("invalid"))
    }

    func testRealHookFallbackDoesNotOverwriteCoveredPrimaryAndRecoversAfterDisconnect() async throws {
        let root = try AgentFixtures.directory(), primary = PrimarySourceFixture()
        let path = root.appendingPathComponent("events.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path, channels: [primary])
        source.setHookFallbackEnabled(true)
        defer { source.stop(); try? FileManager.default.removeItem(at: root) }
        var interaction = AgentInteractionSnapshot(), events: [AgentSessionEvent] = []
        source.start { update in
            if case .interaction(let value) = update { interaction = value }
            if case .event(let event) = update { events.append(event) }
        }
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: AgentFixtures.thread, turnID: "turn-1")
        snapshot.title = "Primary fixture"; snapshot.classification = .userSession; snapshot.status = .running
        snapshot.context.startedAt = Date(); snapshot.context.prompt = "Current message"
        snapshot.context.latestActivity = .tool(name: "Read", detail: "current.swift")
        snapshot.activeToolName = "Read"; snapshot.capabilities = [.lifecycle, .tools, .plans, .messages]
        snapshot.revision = 1
        primary.receive?(.snapshot(snapshot))
        let id = CodexAgentState.id(AgentFixtures.thread)
        XCTAssertEqual(interaction.tools[id], "Read")
        XCTAssertEqual(interaction.receivedEvents, 0)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path), "Covered primary closes the optional listener")
        XCTAssertEqual(interaction.tools[id], "Read")
        primary.receive?(.unavailable(.desktop, [AgentFixtures.thread]))
        XCTAssertNil(interaction.primaryChannels[id])
        XCTAssertEqual(events.last?.status, .unknown)
        XCTAssertTrue(AgentUnixSocket.ownedSocket(path), "Previously enabled fallback resumes on withdrawal")
        var hook = AgentFixtures.envelope("PreToolUse")
        hook.toolName = "Bash"; hook.toolID = "fallback-tool"
        _ = try await Task.detached { try AgentUnixSocket.exchange(hook, path: path, timeout: 2) }.value
        try await NativeUI.waitFor("hook fallback resumes") { interaction.tools[id] == "Bash" }
        let callback = primary.receive
        source.stop()
        let before = events.count
        snapshot.revision = 2
        callback?(.snapshot(snapshot))
        XCTAssertEqual(events.count, before, "Stopped generation rejects delayed primary callbacks")
        XCTAssertTrue(primary.stopped)
    }

    func testExistingOwnersRouteMessagesAndApprovalsWithoutCrossChannelRetries() async throws {
        let root = try AgentFixtures.directory()
        let desktop = PrimarySourceFixture(), daemon = PrimarySourceFixture(kind: .daemon)
        let source = CodexLiveStatusSource(root: root, socketPath: root.appendingPathComponent("events.sock").path,
            channels: [desktop, daemon])
        let manager = AgentManager(sourceFactory: { source })
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let id = CodexAgentState.id(AgentFixtures.thread)
        manager.setEnabled(true)
        let approval = AgentApproval(id: "native-approval", sessionID: id, turnID: "turn-1", tool: "Bash",
            command: "echo fixture", reason: nil, expiresAt: Date().addingTimeInterval(60))
        var native = CodexPrimarySnapshot(kind: .desktop, threadID: id.sessionID, turnID: "turn-1")
        native.classification = .userSession; native.title = "Owner fixture"; native.status = .waitingApproval
        native.approval = approval; native.revision = 1
        native.capabilities = [.lifecycle, .tools, .messages, .progress, .plans, .approvals, .send, .steer, .queue]
        desktop.receive?(.snapshot(native))
        var alternate = CodexPrimarySnapshot(kind: .daemon, threadID: id.sessionID, turnID: "turn-1")
        alternate.classification = .userSession; alternate.title = "Owner fixture"; alternate.status = .running
        alternate.capabilities = native.capabilities; alternate.revision = 1
        daemon.receive?(.snapshot(alternate))
        XCTAssertEqual(manager.interaction.primaryChannels[id], .desktop)
        let capabilities = try XCTUnwrap(manager.interaction.primaryCapabilities[id])
        XCTAssertTrue(capabilities.contains([.messages, .tools, .progress, .approvals]))
        XCTAssertTrue(capabilities.contains([.send, .steer, .queue]))
        manager.respondToApproval(approval.id, decision: .allow)
        manager.respondToApproval(approval.id, decision: .allow)
        try await NativeUI.waitFor("only original Desktop approval is dispatched once") { desktop.decisions == [approval.id] }
        XCTAssertTrue(daemon.decisions.isEmpty)
        native.status = .running; native.approval = nil; native.revision = 2
        desktop.receive?(.snapshot(native))
        let request = AgentMessageRequest(id: UUID(), sessionID: id, turnID: "turn-1", mode: .queue, text: "original owner only")
        desktop.delivery = .uncertain
        let uncertain = await source.send(request)
        XCTAssertEqual(uncertain, .uncertain)
        XCTAssertEqual(desktop.messages, [request]); XCTAssertTrue(daemon.messages.isEmpty)
        let stale = AgentMessageRequest(id: UUID(), sessionID: id, turnID: "stale-turn", mode: .queue, text: "must not send")
        let staleResult = await source.send(stale)
        XCTAssertEqual(staleResult, .failed)
        XCTAssertEqual(desktop.messages.count, 1)
        desktop.receive?(.unavailable(.desktop, [id.sessionID]))
        XCTAssertEqual(manager.interaction.primaryChannels[id], .daemon)
        XCTAssertTrue(manager.interaction.primaryCapabilities[id]?.contains(.queue) == true)
        let next = AgentMessageRequest(id: UUID(), sessionID: id, turnID: "turn-1", mode: .queue, text: "new explicit action after owner change")
        let queued = await source.send(next)
        XCTAssertEqual(queued, .accepted); XCTAssertEqual(daemon.messages, [next])
        manager.refreshConnection()
        await NativeUI.drainMainQueue()
        XCTAssertEqual(desktop.messages.count, 1); XCTAssertEqual(daemon.messages.count, 1)
        XCTAssertTrue(desktop.answers.isEmpty && daemon.answers.isEmpty)
        manager.setEnabled(false)
        manager.respondToApproval(approval.id, decision: .deny)
        XCTAssertEqual(desktop.decisions, [approval.id])
        XCTAssertTrue(desktop.stopped && daemon.stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks.json").path))
    }
}
