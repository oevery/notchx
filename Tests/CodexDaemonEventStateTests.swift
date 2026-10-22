import Foundation
import XCTest
@testable import NotchX

@MainActor
final class CodexDaemonEventStateTests: XCTestCase {
    private let thread = "01a156b9-bfc7-71c1-a986-7ccc73faf51e"

    private func state() throws -> CodexDaemonEventState {
        let metadata: [String: Any] = ["id": thread, "source": "cli", "status": ["type": "idle"],
            "canAcceptDirectInput": true, "updatedAt": 1_600_000_000]
        let snapshot = try XCTUnwrap(CodexDaemonChannel.normalize(thread: metadata, turn: nil))
        var state = CodexDaemonEventState(snapshot: snapshot, turn: nil, directInput: true)
        state.activate()
        return state
    }

    @discardableResult
    private func apply(_ method: String, _ values: [String: Any], to state: inout CodexDaemonEventState) throws -> CodexDaemonEventState.Change {
        var params = values; params["threadId"] = thread
        let safe = try XCTUnwrap(CodexDaemonEventWire.sanitize(["method": method, "params": params], commentaryDelta: true))
        return state.ingest(try XCTUnwrap(JSONSerialization.jsonObject(with: safe) as? [String: Any]))
    }

    func testSubscribedEmptyThreadEarnsOnlyImplementedCoverageThenProcessesPublicLifecycle() throws {
        var state = try state()
        XCTAssertNil(state.snapshot.turnID)
        XCTAssertTrue(state.snapshot.capabilities.isSuperset(of: [.lifecycle, .tools, .messages, .progress, .plans]))
        XCTAssertTrue(state.snapshot.capabilities.intersection([.questions, .approvals, .children]).isEmpty)
        try apply("turn/started", ["turn": ["id": "turn-a", "status": "inProgress", "startedAt": 1_700_000_000]], to: &state)
        try apply("item/completed", ["turnId": "turn-a", "item": ["id": "user-a", "type": "userMessage", "content": [["type": "text", "text": "检查项目"]]]], to: &state)
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "tool-a", "type": "commandExecution", "command": "swift test", "status": "inProgress"]], to: &state)
        XCTAssertEqual(state.snapshot.context.prompt, "检查项目")
        XCTAssertEqual(state.snapshot.activeToolName, "exec_command")
        XCTAssertEqual(state.snapshot.activeToolID, "tool-a")
        try apply("item/completed", ["turnId": "turn-a", "item": ["id": "tool-a", "type": "commandExecution", "command": "swift test", "status": "completed", "aggregatedOutput": "PRIVATE OUTPUT"]], to: &state)
        XCTAssertNil(state.snapshot.activeToolID)
        XCTAssertEqual(state.snapshot.context.lastCompletedTool?.name, "exec_command")
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "comment-a", "type": "agentMessage", "phase": "commentary", "text": "正在核对"]], to: &state)
        try apply("item/agentMessage/delta", ["turnId": "turn-a", "itemId": "comment-a", "delta": "测试"], to: &state)
        XCTAssertEqual(state.snapshot.context.progressText, "正在核对测试")
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "comment-b", "type": "agentMessage", "phase": "commentary", "text": "下一步"]], to: &state)
        try apply("item/agentMessage/delta", ["turnId": "turn-a", "itemId": "comment-a", "delta": "迟到文字"], to: &state)
        try apply("item/completed", ["turnId": "turn-a", "item": ["id": "comment-a", "type": "agentMessage", "phase": "commentary", "text": "旧内容"]], to: &state)
        XCTAssertEqual(state.snapshot.context.progressText, "下一步", "An older commentary cannot append to or replace the current preview")
        try apply("item/agentMessage/delta", ["turnId": "turn-a", "itemId": "comment-b", "delta": "验证"], to: &state)
        XCTAssertEqual(state.snapshot.context.progressText, "下一步验证")
        try apply("turn/plan/updated", ["turnId": "turn-a", "plan": [["step": "读取", "status": "completed"], ["step": "验证", "status": "inProgress"]]], to: &state)
        XCTAssertEqual(state.snapshot.context.plan.map(\.status), ["completed", "in_progress"])
        XCTAssertEqual(state.snapshot.context.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(state.snapshot.revision)
        try apply("turn/completed", ["turn": ["id": "turn-a", "status": "completed", "completedAt": 1_700_000_020]], to: &state)
        XCTAssertEqual(state.snapshot.status, .completed)
        XCTAssertNil(state.snapshot.context.latestActivity)
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "late", "type": "commandExecution", "status": "inProgress", "command": "late"]], to: &state)
        XCTAssertNil(state.snapshot.activeToolID)
    }

    func testUnknownShapeRevokesRelatedCoverageAndRequestsOnlyDisplayWaiting() throws {
        var state = try state()
        try apply("turn/started", ["turn": ["id": "turn-a", "status": "inProgress"]], to: &state)
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "future", "type": "futureTool", "secret": "PRIVATE"]], to: &state)
        XCTAssertFalse(state.snapshot.capabilities.contains(.tools))
        XCTAssertTrue(state.snapshot.capabilities.contains(.lifecycle))
        try apply("item/tool/requestUserInput", ["turnId": "turn-a", "questions": [["question": "PRIVATE QUESTION"]]], to: &state)
        XCTAssertEqual(state.snapshot.status, .waitingInput)
        XCTAssertNil(state.snapshot.context.pendingInput)
        XCTAssertFalse(state.snapshot.capabilities.contains(.questions))
        try apply("thread/status/changed", ["status": ["type": "active", "activeFlags": []]], to: &state)
        XCTAssertEqual(state.snapshot.status, .running)
        try apply("item/commandExecution/requestApproval", ["turnId": "turn-a", "command": "PRIVATE COMMAND"], to: &state)
        XCTAssertEqual(state.snapshot.status, .waitingApproval)
        XCTAssertNil(state.snapshot.approval)
        XCTAssertFalse(state.snapshot.capabilities.contains(.approvals))
        try apply("turn/plan/updated", ["turnId": "turn-a", "plan": [["step": "unknown", "status": "future"]]], to: &state)
        XCTAssertFalse(state.snapshot.capabilities.contains(.plans))
        try apply("item/started", ["turnId": "turn-a", "item": ["id": "future-message", "type": "agentMessage", "phase": "future", "text": "PRIVATE"]], to: &state)
        XCTAssertFalse(state.snapshot.capabilities.contains(.progress))
    }

    func testWireDropsReasoningOutputsDiffsFinalAndUnidentifiedDeltasBeforePendingDelivery() throws {
        for method in ["item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/patchUpdated", "turn/diff/updated"] {
            XCTAssertNil(try CodexDaemonEventWire.sanitize(["method": method, "params": ["threadId": thread, "delta": "PRIVATE"]], commentaryDelta: false))
        }
        XCTAssertNil(try CodexDaemonEventWire.sanitize(["method": "item/agentMessage/delta", "params": ["threadId": thread, "delta": "PRIVATE FINAL"]], commentaryDelta: false))
        let event: [String: Any] = ["method": "item/completed", "params": ["threadId": thread, "turnId": "turn-a", "item": ["type": "agentMessage", "id": "final-a", "phase": "final_answer", "text": "PRIVATE FINAL"]]]
        let safe = try XCTUnwrap(CodexDaemonEventWire.sanitize(event, commentaryDelta: false))
        XCTAssertFalse(String(decoding: safe, as: UTF8.self).contains("PRIVATE"))
        let tool: [String: Any] = ["method": "item/completed", "params": ["threadId": thread, "turnId": "turn-a", "item": ["type": "fileChange", "id": "edit-a", "status": "completed", "changes": [["path": "app.swift", "diff": "PRIVATE DIFF"]], "aggregatedOutput": "PRIVATE OUTPUT"]]]
        let safeTool = try XCTUnwrap(CodexDaemonEventWire.sanitize(tool, commentaryDelta: false))
        XCTAssertFalse(String(decoding: safeTool, as: UTF8.self).contains("PRIVATE"))
        XCTAssertTrue(String(decoding: safeTool, as: UTF8.self).contains("app.swift"))
    }

    func testChildProvenanceAndLastKnownStatesSurviveWireWithoutPromptsOrMessages() throws {
        let childID = "01a156b9-bfc7-71c1-a986-7ccc73faf51f"
        let metadata: [String: Any] = ["id": childID, "parentThreadId": thread, "status": ["type": "notLoaded"], "agentNickname": "Child",
            "source": ["subAgent": ["thread_spawn": ["parent_thread_id": thread, "prompt": "PRIVATE"]]]]
        let safe = try XCTUnwrap(CodexDaemonEventWire.sanitize(["method": "thread/started", "params": ["thread": metadata]], commentaryDelta: false))
        XCTAssertFalse(String(decoding: safe, as: UTF8.self).contains("PRIVATE"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: safe) as? [String: Any])
        let child = try XCTUnwrap(CodexDaemonChannel.childMetadata((object["params"] as! [String: Any])["thread"] as! [String: Any]))
        XCTAssertEqual(child.parentThreadID, thread)
        var state = try state()
        try apply("turn/started", ["turn": ["id": "turn-a", "status": "inProgress"]], to: &state)
        let item: [String: Any] = ["id": "spawn-a", "type": "collabAgentToolCall", "tool": "spawnAgent", "senderThreadId": thread,
            "receiverThreadIds": [childID], "status": "completed", "prompt": "PRIVATE", "agentsStates": [childID: ["status": "completed", "message": "PRIVATE FINAL"]]]
        try apply("item/completed", ["turnId": "turn-a", "item": item], to: &state)
        XCTAssertTrue(state.snapshot.observedChildren.isEmpty, "Receiver IDs alone cannot prove child identity")
        state.observeChild(child)
        XCTAssertEqual(state.snapshot.observedChildren.first?.status, .unknown)
        XCTAssertEqual(state.snapshot.observedChildren.first?.context.lastKnownStatus, .completed)
        XCTAssertNil(state.snapshot.observedChildren.first?.turnID)
        XCTAssertFalse(state.snapshot.capabilities.contains(.children))
        var fresh = state.snapshot; fresh.observedChildren = []
        var runningItem = item
        runningItem["agentsStates"] = [childID: ["status": "running"]]
        state.rebase(fresh, turn: ["id": "turn-a", "items": [runningItem]], eventsBeforeRead: state.eventCount)
        XCTAssertEqual(state.snapshot.observedChildren.first?.context.lastKnownStatus, .running, "A fresh parent page replaces stale child status")
        let wire = try XCTUnwrap(CodexDaemonEventWire.sanitize(["method": "item/completed", "params": ["threadId": thread, "turnId": "turn-a", "item": item]], commentaryDelta: false))
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("PRIVATE"))
        var conflict = metadata
        conflict["source"] = ["subAgent": ["thread_spawn": ["parent_thread_id": childID]]]
        XCTAssertNil(CodexDaemonChannel.childMetadata(conflict))
        XCTAssertNil(CodexDaemonChannel.normalize(thread: conflict, turn: nil))
        conflict["source"] = ["internal": ["prompt": "PRIVATE"]]
        let unknownWire = try XCTUnwrap(CodexDaemonEventWire.sanitize(["method": "thread/started", "params": ["thread": conflict]], commentaryDelta: false))
        let unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: unknownWire) as? [String: Any])
        XCTAssertNil(CodexDaemonChannel.childMetadata((unknown["params"] as! [String: Any])["thread"] as! [String: Any]), "An unsupported source must not become an absent source after filtering")
        XCTAssertFalse(String(decoding: unknownWire, as: UTF8.self).contains("PRIVATE"))
    }
}
