import Foundation
import XCTest
@testable import NotchX

enum AgentFixtures {
    static let thread = "00000000-0000-4000-8000-000000000001"
    static let other = "00000000-0000-4000-8000-000000000002"
    static func envelope(_ event: String, thread: String = thread, turn: String = "turn-1") -> AgentHookEnvelope {
        var value = AgentHookEnvelope(event: event, sessionID: thread, turnID: turn)
        value.threadSource = "user"
        return value
    }
    static func approval(thread: String = thread, command: String = "echo fixture") -> AgentHookEnvelope {
        var value = envelope("PermissionRequest", thread: thread)
        value.reviewer = "user"
        value.command = command
        value.toolName = "Bash"
        value.permissionMode = "default"
        return value
    }
    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/notchx-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

final class CodexAgentHookTests: XCTestCase {
    func testRecentActivityRejectsDelayedProgressAndCompletionsAcrossChannelsAndTurns() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread), date = Date()
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit"), now: date)
        _ = core.ingestTranscript([.progress("Earlier public update", at: date)], thread: id.sessionID, turn: "turn-1")
        var start = AgentFixtures.envelope("PreToolUse"); start.toolID = "read"; start.toolName = "Read"
        start.toolDetail = "App/Modules/Agent/AgentModels.swift"; start.sentAt = date.addingTimeInterval(1)
        _ = core.ingest(start, now: date)
        var finish = AgentFixtures.envelope("PostToolUse"); finish.toolID = "read"; finish.sentAt = date.addingTimeInterval(2)
        _ = core.ingest(finish, now: date)
        let completed = AgentCurrentActivity.completedTool(name: "Read", detail: start.toolDetail)
        XCTAssertEqual(core.snapshot.contexts[id]?.latestActivity, completed)
        _ = core.ingestTranscript([.progress("Delayed old update", at: date), .progress("Untimed update")], thread: id.sessionID, turn: "turn-1")
        XCTAssertEqual(core.snapshot.contexts[id]?.latestActivity, completed)
        _ = core.ingestTranscript([.progress("Now checking results", at: date.addingTimeInterval(3))], thread: id.sessionID, turn: "turn-1")
        XCTAssertEqual(core.snapshot.contexts[id]?.latestActivity, .progress("Now checking results"))
        finish.id = UUID().uuidString
        XCTAssertTrue(core.ingest(finish, now: date).isEmpty, "A duplicate completion with another transport ID cannot regress activity")
        start.id = UUID().uuidString; start.toolID = "next-read"; start.sentAt = date.addingTimeInterval(4)
        _ = core.ingest(start, now: date)
        _ = core.ingestTranscript([.progress("Newer public update", at: date.addingTimeInterval(6))], thread: id.sessionID, turn: "turn-1")
        finish.id = UUID().uuidString; finish.toolID = "next-read"; finish.sentAt = date.addingTimeInterval(5)
        _ = core.ingest(finish, now: date)
        XCTAssertNil(core.snapshot.tools[id])
        XCTAssertEqual(core.snapshot.contexts[id]?.latestActivity, .progress("Newer public update"), "A separately delayed completion must not overwrite newer commentary")
        _ = core.ingest(AgentFixtures.envelope("Stop"), now: date)
        XCTAssertNil(core.snapshot.contexts[id]?.latestActivity)
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"), now: date)
        XCTAssertNil(core.snapshot.contexts[id]?.latestActivity)
        XCTAssertTrue(core.ingestTranscript([.progress("Old turn", at: date.addingTimeInterval(4))], thread: id.sessionID, turn: "turn-1").isEmpty)
    }

    func testCompletionOutcomeUsesOnlyExplicitStructuredStatusWithoutRetainingOutput() throws {
        for (response, expected) in [(["exit_code": 1], AgentToolOutcome.failed), (["is_error": true], .failed),
                                     (["cancelled": true], .cancelled), (["output": "error words do not establish failure"], .completed)] as [([String: Any], AgentToolOutcome)] {
            var core = CodexAgentState()
            _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit"))
            var hook = try AgentHookEnvelope.decodeHook(AgentFixtures.json(["hook_event_name": "PostToolUse",
                "session_id": AgentFixtures.thread, "turn_id": "turn-1", "tool_name": "functions.exec_command",
                "tool_input": ["cmd": "swift test"], "tool_response": response]))
            hook.threadSource = "user"
            _ = core.ingest(hook)
            XCTAssertEqual(core.snapshot.contexts[CodexAgentState.id(AgentFixtures.thread)]?.latestActivity,
                           .completedTool(name: "functions.exec_command", detail: "swift test", outcome: expected))
            XCTAssertNil(hook.message)
        }
    }

    func testFilteredEventsRetainSpecificReasonsWithoutWeakeningTurnOrIdentityChecks() {
        var core = CodexAgentState()
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        var event = AgentFixtures.envelope("PreToolUse"); event.threadSource = "unverified"
        XCTAssertTrue(core.ingest(event).isEmpty)
        XCTAssertTrue(core.ingest(event).isEmpty)
        var missing = AgentFixtures.envelope("PreToolUse"); missing.turnID = nil
        XCTAssertTrue(core.ingest(missing).isEmpty)
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"))
        XCTAssertTrue(core.ingest(AgentFixtures.envelope("PreToolUse")).isEmpty)
        XCTAssertEqual(core.snapshot.rejectionCounts, ["identity": 1, "duplicate": 1, "missingTurn": 1, "oldTurn": 1])
        XCTAssertEqual(core.snapshot.rejectedEvents, 4)
        XCTAssertTrue(core.snapshot.tools.isEmpty)
    }

    func testConcurrentToolsKeepTheRemainingActionAndRecentCompletionPersists() {
        var state = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread), now = Date()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"), now: now)
        var first = AgentFixtures.envelope("PreToolUse")
        first.toolID = "tool-a"; first.toolName = "Bash"; first.toolDetail = "swift build"
        var second = AgentFixtures.envelope("PreToolUse")
        second.toolID = "tool-b"; second.toolName = "Read"; second.toolDetail = "App/Views/CompactView.swift"
        _ = state.ingest(first, now: now); _ = state.ingest(second, now: now)
        var end = AgentFixtures.envelope("PostToolUse"); end.toolID = "tool-a"
        _ = state.ingest(end, now: now)
        XCTAssertEqual(state.snapshot.tools[id], "Read")
        XCTAssertEqual(state.snapshot.contexts[id]?.toolDetail, second.toolDetail)
        end.id = UUID().uuidString; end.toolID = "unmatched-tool"
        _ = state.ingest(end, now: now)
        XCTAssertEqual(state.snapshot.tools[id], "Read", "Unmatched completions cannot clear another tool")
        end.id = UUID().uuidString; end.toolID = "tool-b"
        _ = state.ingest(end, now: now)
        XCTAssertNil(state.snapshot.tools[id])
        let event = state.register(AgentSessionEvent(id: id, runID: nil, requestID: nil, eventID: UUID().uuidString,
            sequence: 1, parentID: nil, classification: .userSession, status: .unknown, title: "Fixture", summary: nil, updatedAt: now))!
        let group = AgentSessionGroup(root: AgentSessionSnapshot(id: id, runID: event.runID, requestID: nil, sequence: event.sequence,
            parentID: nil, classification: .userSession, status: .running, title: "Fixture", summary: nil, updatedAt: now), children: [])
        XCTAssertEqual(AgentPanelPresentation.activity(group: group, context: state.snapshot.contexts[id], tool: nil),
                       .completedTool(name: "Read", detail: second.toolDetail))
        _ = state.ingest(AgentFixtures.envelope("PreCompact"), now: now.addingTimeInterval(60))
        XCTAssertEqual(AgentPanelPresentation.activity(group: group, context: state.snapshot.contexts[id], tool: nil),
                       .completedTool(name: "Read", detail: second.toolDetail), "No timer clears the last real activity")
        XCTAssertEqual(state.snapshot.eventCounts["PreToolUse"], 2)
        XCTAssertEqual(state.snapshot.eventCounts["PostToolUse"], 3)
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"), now: now)
        XCTAssertNil(state.snapshot.contexts[id]?.lastCompletedTool)
    }

    func testNamespacedPlanAndCommandArgumentsDecodeOnBothToolBoundaries() throws {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        let id = CodexAgentState.id(AgentFixtures.thread)
        let input: [String: Any] = ["plan": [["step": "Verify", "status": "in_progress"]]]
        let bytes = try AgentFixtures.json(["hook_event_name": "PostToolUse", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "tool_name": "functions.update_plan", "tool_input": input])
        var plan = try AgentHookEnvelope.decodeHook(bytes); plan.threadSource = "user"
        _ = state.ingest(plan)
        XCTAssertEqual(state.snapshot.contexts[id]?.plan, [AgentPlanStep(step: "Verify", status: "in_progress")])
        let command = try AgentHookEnvelope.decodeHook(AgentFixtures.json(["hook_event_name": "PreToolUse", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "tool_name": "functions.exec_command", "tool_input": ["cmd": "swift build"]]))
        XCTAssertEqual(command.toolDetail, "swift build")
    }

    func testDisplayMetadataUsesCurrentTurnAndIsClearedWithSessionInventory() throws {
        var state = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        var prompt = AgentFixtures.envelope("UserPromptSubmit")
        prompt.userPrompt = String(repeating: "Long prompt ", count: 100)
        prompt.cwd = "/fixture/NotchX"; prompt.branch = "main"; prompt.model = "fixture-model"
        _ = state.ingest(prompt)
        XCTAssertEqual(state.snapshot.contexts[id]?.prompt, AgentMessagePreview.userMessage(prompt.userPrompt))
        XCTAssertEqual(state.snapshot.contexts[id]?.branch, "main")
        let bytes = try AgentFixtures.json(["hook_event_name": "PreToolUse", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "tool_name": "update_plan", "tool_input": ["plan": [
                ["step": "Inspect", "status": "completed"], ["step": "Implement", "status": "in_progress"]]]])
        var plan = try AgentHookEnvelope.decodeHook(bytes); plan.threadSource = "user"
        _ = state.ingest(plan)
        XCTAssertEqual(state.snapshot.contexts[id]?.plan.map { $0.status }, ["completed", "in_progress"])
        var tool = AgentFixtures.envelope("PreToolUse"); tool.toolDetail = "App/Modules/Agent"; tool.toolID = "tool-1"
        _ = state.ingest(tool)
        XCTAssertEqual(state.snapshot.contexts[id]?.toolDetail, tool.toolDetail)
        var post = AgentFixtures.envelope("PostToolUse"); post.toolID = tool.toolID
        _ = state.ingest(post); tool.id = UUID().uuidString; _ = state.ingest(tool)
        XCTAssertNil(state.snapshot.contexts[id]?.toolDetail, "A late PreToolUse cannot restore finished tool details")
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"))
        XCTAssertEqual(state.snapshot.contexts[id]?.plan, [])
        _ = state.ingest(AgentFixtures.envelope("SessionEnd", turn: "turn-2"))
        XCTAssertNil(state.snapshot.contexts[id])
    }

    func testVerifiedEventsEstablishLiveStateWithoutCatalogue() {
        var state = CodexAgentState()
        let events = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        XCTAssertEqual(events.first?.status, .running)
        XCTAssertEqual(events.first?.id.sessionID, AgentFixtures.thread)
        XCTAssertEqual(state.snapshot.liveSessionIDs.count, 1)
    }

    func testUnclassifiedEventsCannotCreateTasksOrApprovalCards() {
        var state = CodexAgentState()
        var event = AgentFixtures.approval()
        event.threadSource = nil
        XCTAssertTrue(state.ingest(event).isEmpty)
        XCTAssertTrue(state.snapshot.approvals.isEmpty)
        XCTAssertTrue(state.snapshot.liveSessionIDs.isEmpty)
    }

    func testSessionStartAndInternalRunsDoNotCreateVisibleActivity() {
        var state = CodexAgentState()
        XCTAssertTrue(state.ingest(AgentFixtures.envelope("SessionStart")).isEmpty)
        var internalEvent = AgentFixtures.envelope("UserPromptSubmit")
        internalEvent.threadSource = "guardian_review"
        XCTAssertTrue(state.ingest(internalEvent).isEmpty)
        XCTAssertTrue(state.snapshot.liveSessionIDs.isEmpty)
    }

    func testSuggestionsAreAttachedWithoutFinishingOrCreatingTasks() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        var event = AgentFixtures.envelope("Stop")
        event.message = #"{"suggestions":[{"title":"Follow up","description":"Add regression coverage"}]}"#
        XCTAssertTrue(state.ingest(event).isEmpty)
        XCTAssertEqual(state.snapshot.liveSessionIDs.count, 1)
        XCTAssertEqual(state.snapshot.suggestions.first?.target?.sessionID, AgentFixtures.thread)
        event.id = UUID().uuidString
        _ = state.ingest(event)
        XCTAssertEqual(state.snapshot.suggestions.count, 1, "Semantic replay must not duplicate suggestions")
        var orphan = event
        orphan.id = UUID().uuidString
        orphan.sessionID = AgentFixtures.other
        XCTAssertTrue(state.ingest(orphan).isEmpty)
        XCTAssertNil(state.snapshot.suggestions.last?.target, "Never guess another conversation")
        XCTAssertEqual(state.snapshot.liveSessionIDs.count, 1)
    }

    func testBusinessJSONContainingSuggestionsIsStillAReply() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        var stop = AgentFixtures.envelope("Stop")
        stop.message = #"{"suggestions":[],"result":"Fixture result"}"#
        XCTAssertEqual(state.ingest(stop).first?.summary, stop.message)
        XCTAssertTrue(state.snapshot.suggestions.isEmpty)
    }

    func testUnknownExplicitSuggestionTargetNeverFallsBackToSourceSession() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        var stop = AgentFixtures.envelope("Stop")
        stop.message = #"{"suggestions":[{"title":"Follow up","prompt":"Check fixture","thread_id":"00000000-0000-4000-8000-000000000002"}]}"#
        XCTAssertTrue(state.ingest(stop).isEmpty)
        XCTAssertEqual(state.snapshot.suggestions.count, 1)
        XCTAssertNil(state.snapshot.suggestions.first?.target)
    }

    func testApprovalIdentityAndConcurrentRequestsStayIndependent() {
        var state = CodexAgentState()
        let first = AgentFixtures.approval()
        let second = AgentFixtures.approval(command: "echo second")
        XCTAssertEqual(state.ingest(first).first?.status, .waitingApproval)
        _ = state.ingest(second)
        XCTAssertEqual(state.snapshot.approvals.count, 2)
        XCTAssertTrue(state.beginDecision(first.id))
        XCTAssertFalse(state.beginDecision(first.id), "A second click must not submit again")
        _ = state.closeRequest(first.id)
        XCTAssertEqual(state.snapshot.approvals.map(\.id), [second.id])
        XCTAssertEqual(state.closeRequest(second.id).first?.status, .unknown)
    }

    func testAutomaticUnknownAndBypassReviewNeverBecomeIslandApprovals() {
        for reviewer in [nil, "guardian_subagent", "guardian"] as [String?] {
            var state = CodexAgentState()
            var event = AgentFixtures.approval()
            event.reviewer = reviewer
            XCTAssertNotEqual(state.ingest(event).first?.status, .waitingApproval)
            XCTAssertTrue(state.snapshot.approvals.isEmpty)
        }
        var state = CodexAgentState()
        var bypass = AgentFixtures.approval()
        bypass.permissionMode = "bypassPermissions"
        XCTAssertEqual(state.ingest(bypass).first?.status, .unknown)
    }

    func testExpiryInterruptAndTurnReplacementInvalidateOldDecisions() {
        var state = CodexAgentState()
        let request = AgentFixtures.approval()
        _ = state.ingest(request)
        XCTAssertFalse(state.beginDecision(request.id, now: Date().addingTimeInterval(120)))
        _ = state.ingest(AgentFixtures.envelope("Interrupt"))
        XCTAssertEqual(state.invalidatedRequests, [request.id])
        XCTAssertFalse(state.beginDecision(request.id))
        XCTAssertEqual(state.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2")).first?.status, .running)
        XCTAssertTrue(state.ingest(AgentFixtures.envelope("Stop")).isEmpty, "Old turn must not finish the replacement")
    }

    func testLateToolEventsCannotReviveFinishedWork() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        var post = AgentFixtures.envelope("PostToolUse")
        post.toolID = "tool-1"
        _ = state.ingest(post)
        var pre = AgentFixtures.envelope("PreToolUse")
        pre.toolID = "tool-1"
        XCTAssertTrue(state.ingest(pre).isEmpty)
        _ = state.ingest(AgentFixtures.envelope("Stop"))
        pre.toolID = "tool-2"
        XCTAssertTrue(state.ingest(pre).isEmpty)
    }

    func testSessionEndRemovesLiveInventoryAndLateEventsCannotReopenIt() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        _ = state.ingest(AgentFixtures.approval())
        _ = state.ingest(AgentFixtures.envelope("SessionEnd"))
        XCTAssertTrue(state.snapshot.approvals.isEmpty)
        XCTAssertTrue(state.retainedSessionIDs.isEmpty)
        XCTAssertTrue(state.ingest(AgentFixtures.envelope("PreToolUse")).isEmpty)
        XCTAssertTrue(state.ingest(AgentFixtures.envelope("UserPromptSubmit")).isEmpty)
        XCTAssertEqual(state.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2")).first?.status, .running)
    }

    func testCompletedParentRejectsLateChildApprovals() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        _ = state.ingest(AgentFixtures.envelope("Stop"))
        var child = AgentFixtures.approval(thread: AgentFixtures.other)
        child.threadSource = "subagent"
        child.parentThreadID = AgentFixtures.thread
        XCTAssertTrue(state.ingest(child).isEmpty)
        XCTAssertTrue(state.snapshot.approvals.isEmpty)
    }

    func testChildActivityUsesActualThreadAndParentSideNotificationsAreIgnored() {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        XCTAssertTrue(state.ingest(AgentFixtures.envelope("SubagentStart")).isEmpty)
        var child = AgentFixtures.envelope("PreToolUse", thread: AgentFixtures.other)
        child.threadSource = "subagent"
        child.parentThreadID = AgentFixtures.thread
        let event = state.ingest(child).first
        XCTAssertEqual(event?.id.sessionID, AgentFixtures.other)
        XCTAssertEqual(event?.parentID?.sessionID, AgentFixtures.thread)
        XCTAssertEqual(event?.classification, .subagent)
    }

    func testParentTerminalClearsChildInventoryBeforeItsNextTurn() {
        for terminal in ["Stop", "Interrupt", "SessionEnd", "UserPromptSubmit"] {
            var state = CodexAgentState()
            _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
            var child = AgentFixtures.approval(thread: AgentFixtures.other)
            child.threadSource = "subagent"
            child.parentThreadID = AgentFixtures.thread
            _ = state.ingest(child)
            XCTAssertEqual(state.snapshot.approvals.count, 1)
            _ = state.ingest(AgentFixtures.envelope(terminal, turn: terminal == "UserPromptSubmit" ? "turn-2" : "turn-1"))
            XCTAssertTrue(state.invalidatedRequests.contains(child.id))
            XCTAssertFalse(state.retainedSessionIDs.contains(CodexAgentState.id(AgentFixtures.other)))
            let next = state.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"))
            XCTAssertEqual(next.first?.status, .running)
            XCTAssertTrue(state.snapshot.approvals.isEmpty)
            XCTAssertEqual(state.snapshot.liveSessionIDs, [CodexAgentState.id(AgentFixtures.thread)])
            child.id = UUID().uuidString
            XCTAssertTrue(state.ingest(child).isEmpty, "Old child events cannot attach to the next parent turn")
        }
    }

    func testHookDecoderBoundsIdentityAndDropsUnneededFields() throws {
        let raw = try AgentFixtures.json(["hook_event_name": "UserPromptSubmit", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "prompt": "Fixture title", "transcript_path": "/not-forwarded", "extra": "unused"])
        let envelope = try AgentHookEnvelope.decodeHook(raw)
        let encoded = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(encoded.contains("not-forwarded"))
        XCTAssertFalse(encoded.contains("unused"))
        let invalid = try AgentFixtures.json(["hook_event_name": "Stop", "session_id": String(repeating: "a", count: 201)])
        XCTAssertThrowsError(try AgentHookEnvelope.decodeHook(invalid), "IDs must be rejected, never truncated into another identity")
        XCTAssertThrowsError(try AgentHookEnvelope.decodeHook(Data(repeating: 32, count: AgentHookEnvelope.maximumBytes + 1)))
    }

    func testOnlyPermissionRequestCanReturnAnApproval() throws {
        for event in ["Stop", "PreToolUse", "UserPromptSubmit"] {
            XCTAssertEqual(String(decoding: AgentHookDecision.allow.hookOutput(for: event), as: UTF8.self), "{}\n")
        }
        let allow = try JSONSerialization.jsonObject(with: AgentHookDecision.allow.hookOutput(for: "PermissionRequest")) as? [String: Any]
        let output = allow?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual((output?["decision"] as? [String: Any])?["behavior"] as? String, "allow")
    }

    func testPreviousStopHookContinuationDoesNotClaimCurrentRunIsStillRunning() throws {
        var state = CodexAgentState()
        _ = state.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        let bytes = try AgentFixtures.json(["hook_event_name": "Stop", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "stop_hook_active": true])
        XCTAssertEqual(state.ingest(try AgentHookEnvelope.decodeHook(bytes)).first?.status, .completed)
    }
}

final class CodexHookMetadataTests: XCTestCase {
    func testExactTranscriptReviewerAndChildIdentity() throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.jsonl")
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": AgentFixtures.other, "parent_thread_id": AgentFixtures.thread, "thread_source": "subagent", "cwd": "/fixture/NotchX", "git": ["branch": "main"], "base_instructions": String(repeating: "fixture", count: 4000)]],
            ["type": "turn_context", "payload": ["turn_id": "old-turn", "approvals_reviewer": "user"]],
            ["type": "turn_context", "payload": ["turn_id": "turn-1", "approvals_reviewer": "guardian_subagent", "model": "fixture-model"]]
        ]
        var bytes = Data()
        for record in records { bytes.append(try AgentFixtures.json(record)); bytes.append(10) }
        try bytes.write(to: file)
        let input = try AgentFixtures.json(["transcript_path": file.path])
        var envelope = AgentFixtures.approval()
        envelope.agentID = AgentFixtures.other
        envelope.reviewer = nil
        CodexHookMetadata.enrich(&envelope, input: input, root: root)
        XCTAssertEqual(envelope.sessionID, AgentFixtures.other)
        XCTAssertEqual(envelope.parentThreadID, AgentFixtures.thread)
        XCTAssertEqual(envelope.reviewer, "guardian_subagent")
        XCTAssertEqual(envelope.cwd, "/fixture/NotchX")
        XCTAssertEqual(envelope.branch, "main")
        XCTAssertEqual(envelope.model, "fixture-model")
    }

    func testTranscriptEscapeAndMismatchedIdentityCannotDelegateApproval() throws {
        let root = try AgentFixtures.directory(), outside = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("outside.jsonl")
        var bytes = try AgentFixtures.json(["type": "session_meta", "payload": ["id": AgentFixtures.thread]])
        bytes.append(10)
        bytes.append(try AgentFixtures.json(["type": "turn_context", "payload": ["turn_id": "turn-1", "approvals_reviewer": "user"]]))
        try bytes.write(to: file)
        let link = sessions.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var envelope = AgentFixtures.approval()
        envelope.reviewer = nil
        CodexHookMetadata.enrich(&envelope, input: try AgentFixtures.json(["transcript_path": link.path]), root: root)
        XCTAssertNil(envelope.reviewer)
        XCTAssertEqual(envelope.threadSource, "unverified")
        let local = sessions.appendingPathComponent("wrong.jsonl")
        try bytes.write(to: local)
        envelope.sessionID = AgentFixtures.other
        CodexHookMetadata.enrich(&envelope, input: try AgentFixtures.json(["transcript_path": local.path]), root: root)
        XCTAssertNil(envelope.reviewer)
    }
}
