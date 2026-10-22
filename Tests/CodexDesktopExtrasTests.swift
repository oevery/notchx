import Foundation
import XCTest
@testable import NotchX

final class CodexDesktopExtrasTests: XCTestCase {
    private let child = "00000000-0000-4000-8000-000000000099"
    private func projection(_ items: [[String: Any]], terminal: Bool = false) throws -> (CodexPrimarySnapshot, [String: Any]) {
        let state: [String: Any] = ["id": AgentFixtures.thread, "hostId": "local", "threadSource": "user", "resumeState": "resumed",
            "threadRuntimeStatus": ["type": terminal ? "idle" : "active", "activeFlags": []], "requests": [],
            "turns": [["turnId": "turn-1", "status": terminal ? "completed" : "inProgress", "items": items]]]
        var stream = CodexDesktopStreamState(thread: AgentFixtures.thread, owner: "owner")
        let result = stream.consume(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "sourceClientId": "owner", "params": ["conversationId": AgentFixtures.thread, "hostId": "local",
                "change": ["type": "snapshot", "revision": 1, "conversationState": state]]])
        guard case .snapshot(let value) = result else { XCTFail("Expected projection"); throw AgentHookWireError.invalidMessage }
        return (value, try XCTUnwrap(stream.document))
    }

    func testAsyncQuestionMetadataSurvivesFinalBodyRedactionAndOnlyAcceptedAnswersResolveIt() throws {
        let question: [String: Any] = ["id": "async-message", "type": "agentMessage", "phase": "final_answer", "delivery": "async",
            "text": "PRIVATE_FINAL_BODY", "questions": [["title": "Which viewport?", "options": ["Desktop", "Mobile"]]]]
        let (waiting, document) = try projection([question])
        let input = try XCTUnwrap(waiting.context.pendingInput)
        XCTAssertTrue(input.asynchronous); XCTAssertFalse(input.canRespond)
        XCTAssertEqual(input.questions.first?.options.map(\.label), ["Desktop", "Mobile"])
        XCTAssertEqual(waiting.status, .waitingInput)
        XCTAssertFalse(String(decoding: try AgentFixtures.json(document), as: UTF8.self).contains("PRIVATE_FINAL_BODY"))
        let replies = try JSONSerialization.data(withJSONObject: [["questionItemId": input.id, "question": input.text, "answer": "Desktop"]])
        let wrapper = "<send_user_message_question_reply>\n" + String(decoding: replies, as: UTF8.self) + "\n</send_user_message_question_reply>"
        var steer: [String: Any] = ["id": "reply", "type": "steeringUserMessage", "status": "pending",
            "input": [["type": "text", "text": wrapper]]]
        XCTAssertNotNil(try projection([question, steer]).0.context.pendingInput)
        steer["status"] = "accepted"
        XCTAssertNil(try projection([question, steer]).0.context.pendingInput)
        XCTAssertNil(try projection([question], terminal: true).0.context.pendingInput)
        XCTAssertNil(AgentMessagePreview.userMessage(wrapper))
    }

    private func spawn(parent: String = AgentFixtures.thread) -> [String: Any] {
        ["id": "spawn", "type": "collabAgentToolCall", "tool": "spawnAgent", "senderThreadId": AgentFixtures.thread,
         "receiverThreadIds": [child], "receiverThreads": [["threadId": child, "thread": [
            "id": child, "parentThreadId": parent, "source": ["subAgent": ["thread_spawn": ["parent_thread_id": parent]]],
            "agentNickname": "Fixture child", "model": "fixture-model", "turns": []]]],
         "agentsStates": [child: ["status": "running", "message": "PRIVATE_CHILD_OUTPUT"]]]
    }

    func testParentProvenanceDiscoversChildButDoesNotInventLiveTurnOrExtraRootCount() throws {
        let last: [String: Any] = ["id": "wait", "type": "collabAgentToolCall", "tool": "wait", "senderThreadId": AgentFixtures.thread,
            "receiverThreadIds": [child], "agentsStates": [child: ["status": "completed"]]]
        let (root, document) = try projection([spawn(), last])
        let observed = try XCTUnwrap(root.observedChildren.first)
        XCTAssertNil(observed.turnID); XCTAssertTrue(observed.capabilities.isEmpty)
        XCTAssertEqual(observed.status, .unknown); XCTAssertEqual(observed.context.lastKnownStatus, .completed)
        XCTAssertEqual(observed.parentThreadID, AgentFixtures.thread)
        XCTAssertFalse(String(decoding: try AgentFixtures.json(document), as: UTF8.self).contains("PRIVATE_CHILD_OUTPUT"))
        var core = CodexAgentState(), store = AgentSessionStore()
        for event in core.ingestPrimary(root) + core.setObservedChildren(root.observedChildren, parent: root.threadID) { _ = store.ingest(event) }
        XCTAssertEqual(store.groups.count, 1); XCTAssertEqual(store.groups.first?.children.count, 1)
        XCTAssertEqual(core.snapshot.contexts[CodexAgentState.id(child)]?.lastKnownStatus, .completed)
        _ = core.losePrimary(kind: .desktop, threads: [root.threadID])
        XCTAssertFalse(core.retainedSessionIDs.contains(CodexAgentState.id(child)))
        XCTAssertNil(core.snapshot.contexts[CodexAgentState.id(child)])
        XCTAssertTrue(try projection([spawn(parent: AgentFixtures.other)]).0.observedChildren.isEmpty)
    }
}
