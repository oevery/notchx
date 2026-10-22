import Foundation
import XCTest
@testable import NotchX

@MainActor
private final class AgentMessageFixtureSource: AgentInteractiveSource {
    var receive: (@MainActor (AgentSourceUpdate) -> Void)?
    var messages: [AgentMessageRequest] = []
    var pending: CheckedContinuation<AgentMessageDelivery, Never>?
    var completesImmediately = false
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery {
        messages.append(request)
        if completesImmediately { return .accepted }
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ delivery: AgentMessageDelivery) { pending?.resume(returning: delivery); pending = nil }
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) { self.receive = receive; receive(.connection(.connected)) }
    func stop() { receive = nil }
    func respond(id: String, decision: AgentHookDecision) {}

}

@MainActor
final class AgentExperienceTests: XCTestCase {
    func testComposerModesAndDraftsStayWithOriginalSessions() async throws {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { source.finish(.failed); manager.setEnabled(false) }
        publish(a, source: source); publish(b, source: source, status: .completed)
        source.receive?(.interaction(AgentInteractionSnapshot(primaryChannels: [a: .desktop, b: .daemon],
            primaryCapabilities: [a: [.steer, .queue], b: [.send]])))
        manager.setMessageDraft("literal $(text) 第二行\n", for: a)
        manager.setMessageDraft("another draft", for: b)
        XCTAssertEqual(manager.messageMode(for: a), .steer); XCTAssertEqual(manager.messageMode(for: b), .send)
        XCTAssertFalse(manager.canSendMessage(to: a, mode: .send))
        XCTAssertFalse(manager.canSendMessage(to: b, mode: .queue))
        manager.selectSession(b); manager.leavePanel(); manager.selectSession(a)
        XCTAssertEqual(manager.draft(for: a).text, "literal $(text) 第二行\n")
        manager.sendMessage(to: a, mode: .queue); manager.sendMessage(to: a, mode: .steer)
        try await NativeUI.waitFor("one original-session request") { source.pending != nil }
        XCTAssertEqual(source.messages.count, 1)
        XCTAssertEqual(source.messages.first?.sessionID, a); XCTAssertEqual(source.messages.first?.turnID, "turn-1")
        XCTAssertEqual(source.messages.first?.mode, .queue)
        manager.setMessageDraft("typed during submission", for: a)
        source.finish(.accepted)
        try await NativeUI.waitFor("queue acknowledgement") { manager.draft(for: a).delivery == .accepted }
        XCTAssertEqual(manager.draft(for: a).text, "typed during submission")
        XCTAssertEqual(manager.draft(for: b).text, "another draft")
        manager.sendMessage(to: b, mode: .send)
        try await NativeUI.waitFor("terminal original-session request") { source.pending != nil }
        source.finish(.accepted)
        try await NativeUI.waitFor("confirmed unchanged draft clears") { manager.draft(for: b).text.isEmpty }
        XCTAssertEqual(source.messages.last?.sessionID, b)
    }

    func testFailedAndUncertainSendsPreserveDraftAndPreventBlindResubmission() async throws {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { source.finish(.failed); manager.setEnabled(false) }
        publish(a, source: source)
        source.receive?(.interaction(AgentInteractionSnapshot(primaryCapabilities: [a: [.steer, .queue]])))
        manager.setMessageDraft("keep this message", for: a)
        manager.sendMessage(to: a, mode: .steer)
        try await NativeUI.waitFor("first attempt") { source.pending != nil }
        source.finish(.failed)
        try await NativeUI.waitFor("definite failure") { manager.draft(for: a).delivery == .failed }
        XCTAssertEqual(manager.draft(for: a).text, "keep this message")
        manager.sendMessage(to: a, mode: .steer)
        try await NativeUI.waitFor("manual second attempt") { source.pending != nil }
        source.finish(.uncertain)
        try await NativeUI.waitFor("unknown receipt") { manager.draft(for: a).delivery == .uncertain }
        manager.setMessageDraft("new text after unknown receipt", for: a)
        manager.sendMessage(to: a, mode: .queue)
        XCTAssertEqual(source.messages.count, 2)
        XCTAssertFalse(manager.canSendMessage(to: a, mode: .steer))
        manager.acknowledgeUncertainMessage(for: a)
        XCTAssertTrue(manager.canSendMessage(to: a, mode: .steer))
        manager.sendMessage(to: a, mode: .steer)
        try await NativeUI.waitFor("third attempt") { source.pending != nil }
        manager.setCodexEnabled(false)
        source.finish(.accepted)
        await NativeUI.drainMainQueue()
        XCTAssertEqual(manager.draft(for: a).delivery, .uncertain)
        XCTAssertEqual(manager.draft(for: a).text, "new text after unknown receipt")
    }

    func testComposerDoesNotSendWithoutLiveCapabilityOrWithOversizedOrBlankText() async throws {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        source.completesImmediately = true
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        publish(a, source: source)
        manager.setMessageDraft("draft", for: a)
        XCTAssertFalse(manager.canSendMessage(to: a, mode: .steer))
        manager.sendMessage(to: a, mode: .steer)
        source.receive?(.interaction(AgentInteractionSnapshot(primaryCapabilities: [a: [.steer]])))
        for text in [" \n\t", String(repeating: "长", count: 11_000)] {
            manager.setMessageDraft(text, for: a)
            XCTAssertFalse(manager.canSendMessage(to: a, mode: .steer))
            manager.sendMessage(to: a, mode: .steer)
        }
        manager.setMessageDraft("valid", for: a)
        for (index, status) in [AgentActivityStatus.waitingInput, .waitingApproval, .unknown].enumerated() {
            publish(a, source: source, sequence: Int64(index + 2), status: status)
            XCTAssertFalse(manager.canSendMessage(to: a, mode: .steer))
            manager.sendMessage(to: a, mode: .steer)
        }
        await NativeUI.drainMainQueue()
        XCTAssertTrue(source.messages.isEmpty)
        publish(a, source: source, turn: "valid-turn", sequence: 6)
        manager.sendMessage(to: a, mode: .steer)
        try await NativeUI.waitFor("valid input reaches the same real dispatch entry") {
            source.messages.count == 1 && manager.draft(for: a).delivery == .accepted
        }
        XCTAssertEqual(source.messages.first?.text, "valid")
        XCTAssertEqual(source.messages.first?.sessionID, a)
        XCTAssertEqual(source.messages.first?.turnID, "valid-turn")
    }
    func testIndependentCodexChoicePersistsAndModuleEnableCannotRestartADisabledProvider() throws {
        let domain = "app.notchx.tests.agent-choice." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let source = AgentMessageFixtureSource()
        var creations = 0
        let manager = AgentManager(sourceFactory: { creations += 1; return source }, preferenceStore: preferences)
        defer { manager.setEnabled(false) }
        XCTAssertTrue(manager.codexEnabled, "Existing users retain their previous opt-in through the module switch")
        manager.setEnabled(true)
        publish(a, source: source)
        let oldCallback = source.receive
        manager.setCodexEnabled(false)
        XCTAssertTrue(manager.isEnabled); XCTAssertFalse(manager.isCodexActive)
        XCTAssertNil(source.receive); XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertFalse(preferences.bool(forKey: AgentManager.codexEnabledKey))
        oldCallback?(.connection(.connected))
        oldCallback?(.interaction(AgentInteractionSnapshot(receivedEvents: 99)))
        XCTAssertEqual(manager.connection, .disconnected); XCTAssertEqual(manager.interaction.receivedEvents, 0)
        manager.setEnabled(false); manager.setEnabled(true)
        XCTAssertEqual(creations, 1, "Module reactivation must not construct a disabled provider")
        let restored = AgentManager(sourceFactory: { creations += 1; return source }, preferenceStore: preferences)
        defer { restored.setEnabled(false) }
        restored.setEnabled(true)
        XCTAssertFalse(restored.codexEnabled); XCTAssertEqual(creations, 1)
        restored.setEnabled(false)
        restored.setCodexEnabled(true)
        XCTAssertEqual(creations, 1, "Changing a saved choice while the module is off cannot start I/O")
        restored.setEnabled(true)
        XCTAssertEqual(creations, 2); XCTAssertTrue(restored.isCodexActive)
        XCTAssertTrue(preferences.bool(forKey: AgentManager.codexEnabledKey))
        oldCallback?(.interaction(AgentInteractionSnapshot(receivedEvents: 100)))
        XCTAssertEqual(restored.interaction.receivedEvents, 0)
    }

    func testQuestionAttentionWaitsForInteractionAndIsShownOnce() {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        publish(a, source: source); publish(b, source: source, status: .waitingInput)
        manager.selectSession(a); manager.setPanelEditing(true)
        let context = AgentSessionContext(pendingInput: AgentPendingInput(id: "question-1", text: "Pick one", asynchronous: true))
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [a, b], contexts: [b: context])))
        XCTAssertEqual(manager.panel.route, .detail(a)); XCTAssertNil(manager.attentionRequestID)
        manager.setPanelEditing(false)
        XCTAssertEqual(manager.panel.route, .detail(b)); XCTAssertTrue(manager.attentionRequestID?.hasPrefix("input-") == true)
        let request = manager.attentionRequestID
        manager.setPanelEditing(false)
        XCTAssertEqual(manager.attentionRequestID, request)
    }

    func testUserPreviewNormalizesTextAndRejectsAttachmentOnlyOrUnclosedWrappers() {
        XCTAssertNil(AgentMessagePreview.userMessage(" \n\t "))
        XCTAssertNil(AgentMessagePreview.userMessage("<image name='fixture'>bytes</image>"))
        XCTAssertNil(AgentMessagePreview.userMessage("<image name='fixture'>unclosed"))
        XCTAssertEqual(AgentMessagePreview.userMessage("\n <image name='fixture'>bytes</image>\n检查\t当前布局\n再检查切换"), "检查 当前布局 再检查切换")
        XCTAssertEqual(AgentMessagePreview.userMessage("# Files mentioned by the user:\nattachment\n## My request:\n修复布局"), "修复布局")
        XCTAssertEqual(AgentMessagePreview.userMessage("Keep <custom>literal user content</custom>"), "Keep <custom>literal user content</custom>")
        XCTAssertEqual(AgentMessagePreview.userMessage(String(repeating: "长", count: 8000))?.count, 240)
    }

    func testUserPreviewStaysWithItsTurnAndSameTurnInputKeepsRealProgress() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        var first = AgentFixtures.envelope("UserPromptSubmit"); first.userPrompt = "\n  检查布局"
        _ = core.ingest(first)
        var work = AgentFixtures.envelope("PreToolUse"); work.toolName = "Read"; work.toolDetail = "App/Views/CompactView.swift"
        work.plan = [AgentPlanStep(step: "检查侧槽", status: "in_progress")]
        _ = core.ingest(work)
        var followUp = AgentFixtures.envelope("UserPromptSubmit"); followUp.userPrompt = "补充一项检查"
        _ = core.ingest(followUp)
        let context = core.snapshot.contexts[id]
        XCTAssertEqual(AgentPanelPresentation.userMessage(context: context, turnID: "turn-1"), "补充一项检查")
        XCTAssertEqual(context?.startedAt, first.sentAt)
        XCTAssertEqual(context?.plan, work.plan)
        XCTAssertEqual(context?.toolDetail, work.toolDetail)
        XCTAssertNil(AgentPanelPresentation.userMessage(context: context, turnID: "turn-2"))
        var next = AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2")
        next.title = "A catalogue title is not a user prompt"
        _ = core.ingest(next)
        XCTAssertNil(AgentPanelPresentation.userMessage(context: core.snapshot.contexts[id], turnID: "turn-2"))
        XCTAssertEqual(core.snapshot.contexts[id]?.plan, [])
        XCTAssertNil(AgentPanelPresentation.userMessage(context: CodexAgentState().snapshot.contexts[id], turnID: "turn-2"))
    }

    func testActivityNeverFallsBackToAPlanOrReusesAnEndedReply() {
        var context = AgentSessionContext(toolDetail: "App/Views/CompactView.swift", plan: [AgentPlanStep(step: "检查布局", status: "in_progress")])
        XCTAssertEqual(AgentPanelPresentation.activity(group: group(a), context: context, tool: "Read"), .tool(name: "Read", detail: context.toolDetail))
        XCTAssertEqual(AgentPanelPresentation.activity(group: group(a), context: context, tool: nil), .waiting)
        context.plan = []
        XCTAssertEqual(AgentPanelPresentation.activity(group: group(a), context: context, tool: nil), .waiting)
        XCTAssertNil(AgentPanelPresentation.activity(group: group(a, status: .completed), context: context, tool: "Read"))
    }

    private let a = CodexAgentState.id(AgentFixtures.thread)
    private let b = CodexAgentState.id(AgentFixtures.other)

    private func group(_ id: AgentSessionID, status: AgentActivityStatus = .running, turn: String = "turn-1", date: TimeInterval = 0) -> AgentSessionGroup {
        AgentSessionGroup(root: AgentSessionSnapshot(id: id, runID: turn, requestID: nil, sequence: 1,
            parentID: nil, classification: .userSession, status: status, title: id.sessionID, summary: nil,
            updatedAt: Date(timeIntervalSince1970: date)), children: [])
    }
    private func approval(_ id: AgentSessionID, key: String) -> AgentApproval {
        AgentApproval(id: key, sessionID: id, turnID: "turn-1", tool: "Bash", command: "echo fixture",
            reason: nil, expiresAt: Date().addingTimeInterval(60))
    }
    private func publish(_ id: AgentSessionID, source: AgentMessageFixtureSource, turn: String = "turn-1", sequence: Int64 = 1, status: AgentActivityStatus = .running) {
        source.receive?(.event(AgentSessionEvent(id: id, runID: turn, requestID: nil, eventID: UUID().uuidString,
            sequence: sequence, parentID: nil, classification: .userSession, status: status,
            title: "Fixture", summary: nil, updatedAt: Date())))
    }

    func testStableListDefersPriorityChangesAndDoesNotReplaceAnActiveApproval() {
        var state = AgentPanelState(), interaction = AgentInteractionSnapshot()
        XCTAssertNil(state.reconcile(groups: [group(a), group(b)], interaction: interaction))
        XCTAssertEqual(state.order, [a,b])
        state.isListInteracting = true
        interaction.approvals = [approval(b, key: "b")]
        XCTAssertNil(state.reconcile(groups: [group(b, status: .waitingApproval), group(a, date: 20)], interaction: interaction))
        XCTAssertEqual(state.order, [a,b]); XCTAssertEqual(state.route, .sessions)
        state.isListInteracting = false
        XCTAssertEqual(state.reconcile(groups: [group(b, status: .waitingApproval), group(a)], interaction: interaction), "b")
        XCTAssertEqual(state.order, [b,a])
        state.route = .approval("b")
        interaction.approvals.append(approval(a, key: "a"))
        XCTAssertNil(state.reconcile(groups: [group(a, status: .waitingApproval), group(b, status: .waitingApproval)], interaction: interaction))
        XCTAssertEqual(state.route, .approval("b"))
        interaction.approvals.removeAll { $0.id == "b" }
        XCTAssertEqual(state.reconcile(groups: [group(a, status: .waitingApproval), group(b)], interaction: interaction), "a")
        XCTAssertEqual(state.route, .approval("a"), "The next queued request appears after resolving the current one")
    }

    func testSuggestionsDoNotChangeSessionRoutingOrAttention() {
        var state = AgentPanelState()
        state.route = .detail(a)
        let suggestion = AgentSuggestion(id: "suggestion", target: a, sourceTurnID: "turn-1",
            title: "Next", text: "Run a regression", targetTurnID: "turn-1")
        XCTAssertNil(state.reconcile(groups: [group(a, status: .completed)],
            interaction: AgentInteractionSnapshot(suggestions: [suggestion])))
        XCTAssertEqual(state.route, .detail(a))
        XCTAssertEqual(state.order, [a])
    }

    func testApprovalQueuesWhileEditingWithoutStealingTheSelectedSession() {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        publish(a, source: source); publish(b, source: source)
        manager.selectSession(a); manager.setPanelEditing(true)
        source.receive?(.interaction(AgentInteractionSnapshot(approvals: [approval(b, key: "b")])))
        XCTAssertEqual(manager.panel.route, .detail(a)); XCTAssertNil(manager.attentionRequestID)
        manager.setPanelEditing(false)
        XCTAssertEqual(manager.panel.route, .approval("b"))
        XCTAssertEqual(manager.attentionRequestID, "b")
    }

    func testCatalogueHistoryDoesNotIncreaseTheCompactLiveCountAndCanBeBrowsed() {
        let source = AgentMessageFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        publish(a, source: source); publish(b, source: source, status: .unknown)
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [a])))
        XCTAssertEqual(manager.liveGroups.map { $0.id }, [a])
        XCTAssertEqual(manager.recentGroups.map { $0.id }, [b])
        XCTAssertEqual(manager.defaultDetailGroup?.id, a)
        manager.showSessionList()
        XCTAssertTrue(manager.panel.prefersSessionList)
        manager.selectSession(b)
        XCTAssertEqual(manager.panel.route, .detail(b))
        manager.leavePanel()
        XCTAssertFalse(manager.panel.prefersSessionList)
    }
}
