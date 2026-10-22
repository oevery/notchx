import Foundation
import XCTest
@testable import NotchX

final class CodexTranscriptObserverTests: XCTestCase {
    func testProgressPreservesSourceTimestampForCrossChannelOrdering() throws {
        for timestamp in ["2026-10-20T08:00:01.250Z", "2026-10-20T08:00:01Z"] {
            var parser = CodexTranscriptParser(turnID: "turn-1")
            let record = try AgentFixtures.json(["type": "response_item", "timestamp": timestamp,
                "payload": ["type": "message", "role": "assistant", "phase": "commentary",
                            "content": [["type": "output_text", "text": "Checking results"]]]])
            guard case .progress(let text, let at) = parser.consume(record) else { return XCTFail("Missing public progress") }
            XCTAssertEqual(text, "Checking results")
            XCTAssertNotNil(at)
        }
    }

    private func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        try AgentFixtures.json(["type": type, "payload": payload])
    }

    func testOnlyPublicCommentaryIsProgressAndOtherTurnsCannotLeak() throws {
        var parser = CodexTranscriptParser(turnID: "turn-1")
        XCTAssertNil(parser.consume(try line("response_item", ["type": "reasoning", "text": "private"])))
        XCTAssertNil(parser.consume(try line("response_item", ["type": "message", "role": "assistant", "channel": "final",
            "content": [["type": "output_text", "text": "long reply"]]])))
        let progress = try line("response_item", ["type": "message", "role": "assistant", "channel": "commentary",
            "content": [["type": "output_text", "text": "检查  当前布局 与边界"]]])
        XCTAssertEqual(parser.consume(progress), .progress("检查 当前布局 与边界"))
        let native = try line("response_item", ["type": "message", "role": "assistant", "phase": "commentary",
            "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            "content": [["type": "output_text", "text": "Native public progress"]]])
        XCTAssertEqual(parser.consume(native), .progress("Native public progress"))
        parser.invalidateScope()
        XCTAssertNil(parser.consume(progress))
        XCTAssertEqual(parser.consume(native), .progress("Native public progress"))
        XCTAssertNil(parser.consume(try line("turn_context", ["turn_id": "turn-2"])))
        XCTAssertNil(parser.consume(progress))
        XCTAssertNil(parser.consume(try line("turn_context", ["turn_id": "turn-1"])))
        XCTAssertEqual(parser.consume(progress), .progress("检查 当前布局 与边界"))
        XCTAssertNil(parser.consume(try line("event_msg", ["type": "task_started", "turn_id": "turn-2"])))
        XCTAssertNil(parser.consume(progress))
        XCTAssertNil(parser.consume(try line("turn_context", ["turn_id": "turn-1"])))
        XCTAssertEqual(parser.consume(try line("event_msg", ["type": "task_complete", "turn_id": "turn-1"])), .ended)
        XCTAssertNil(parser.consume(progress))
        var cancelled = CodexTranscriptParser(turnID: "turn-1")
        XCTAssertEqual(cancelled.consume(try line("event_msg", ["type": "turn_aborted", "turn_id": "turn-1"])), .cancelled)
    }

    func testAsyncQuestionRemainsAfterAcceptedOutputUntilUserAnswers() throws {
        for asynchronous in [false, true] {
            var parser = CodexTranscriptParser(turnID: "turn-1")
            let args = try AgentFixtures.json(["questions": [[asynchronous ? "title" : "question": "Which approach?"]]])
            let question = AgentPendingInput(id: "question-1", text: "Which approach?", asynchronous: asynchronous)
            XCTAssertEqual(parser.consume(try line("response_item", ["type": "function_call", "name": asynchronous ? "request_user_input_async" : "request_user_input",
                "call_id": "question-1", "arguments": String(decoding: args, as: UTF8.self)])), .question(question))
            let output = try line("response_item", ["type": "function_call_output", "call_id": "question-1", "output": "accepted"])
            XCTAssertEqual(parser.consume(output), asynchronous ? nil : .answered)
            XCTAssertEqual(parser.consume(try line("event_msg", ["type": "user_message"])), .answered)
            XCTAssertEqual(parser.consume(try line("response_item", ["type": "message", "role": "user"])), .answered)
        }
    }

    func testVerifiedSignalsDoNotInflateHookCountsOrReviveOldRuns() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit"))
        let count = core.snapshot.receivedEvents
        let input = AgentPendingInput(id: "question-1", text: "Pick one", asynchronous: true)
        XCTAssertEqual(core.ingestTranscript([.progress("Checking layout"), .question(input)], thread: id.sessionID, turn: "turn-1").first?.status, .waitingInput)
        XCTAssertEqual(core.snapshot.contexts[id]?.progressText, "Checking layout")
        XCTAssertEqual(core.snapshot.receivedEvents, count)
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-2"))
        XCTAssertTrue(core.ingestTranscript([.question(input)], thread: id.sessionID, turn: "turn-1").isEmpty)
        XCTAssertNil(core.snapshot.contexts[id]?.pendingInput)
        _ = core.ingestTranscript([.ended], thread: id.sessionID, turn: "turn-2")
        XCTAssertFalse(core.acceptsTranscript(thread: id.sessionID, turn: "turn-2"))
        XCTAssertTrue(core.ingestTranscript([.progress("late")], thread: id.sessionID, turn: "turn-2").isEmpty)
        _ = core.ingest(AgentFixtures.envelope("UserPromptSubmit", turn: "turn-3"))
        XCTAssertEqual(core.ingestTranscript([.cancelled], thread: id.sessionID, turn: "turn-3").first?.status, .cancelled)
    }

    func testObserverRejectsWrongThreadAndOutsideRoot() throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("fixture.jsonl")
        var header = try line("session_meta", ["id": AgentFixtures.thread, "thread_source": "user"]); header.append(10)
        try header.write(to: file)
        XCTAssertThrowsError(try CodexTranscriptObserver(file: file, root: root, sessionID: AgentFixtures.other, turnID: "turn-1", receive: { _ in }))
        XCTAssertThrowsError(try CodexTranscriptObserver(file: file, root: sessions, sessionID: AgentFixtures.thread, turnID: "turn-1", receive: { _ in }))
    }
}
