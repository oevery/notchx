import Foundation
import XCTest
@testable import NotchX

final class CodexPrimaryStateTests: XCTestCase {
    func testKnownNativeQuestionCanBeDisplayedAndResolvedWithoutClaimingAllQuestionCoverage() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        var value = CodexPrimarySnapshot(kind: .desktop, threadID: id.sessionID, turnID: "turn-1")
        value.classification = .userSession; value.status = .waitingInput; value.revision = 1
        value.context.pendingInput = AgentPendingInput(id: "known-question", text: "Choose a viewport", asynchronous: false)
        _ = core.ingestPrimary(value)
        XCTAssertEqual(core.snapshot.contexts[id]?.pendingInput?.id, "known-question")
        XCTAssertFalse(value.capabilities.contains(.questions))
        value.revision = 2; value.status = .running; value.context.pendingInput = nil
        _ = core.ingestPrimary(value)
        XCTAssertNil(core.snapshot.contexts[id]?.pendingInput)
    }

    func testPrimaryProgressDoesNotInventHookReceiptsAndRejectsStaleRevisions() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        var primary = CodexPrimarySnapshot(kind: .desktop, threadID: id.sessionID, turnID: "turn-1")
        primary.title = "Primary fixture"; primary.classification = .userSession; primary.status = .running
        primary.context.prompt = "A bounded current user message"
        primary.context.startedAt = Date(); primary.context.latestActivity = .tool(name: "Read", detail: "main.swift")
        primary.activeToolName = "Read"; primary.revision = 7; primary.capabilities = [.lifecycle, .tools, .messages, .progress]
        XCTAssertEqual(core.ingestPrimary(primary).first?.status, .running)
        XCTAssertEqual(core.snapshot.receivedEvents, 0)
        XCTAssertEqual(core.snapshot.primaryChannels[id], .desktop)
        XCTAssertEqual(core.snapshot.contexts[id]?.prompt, "A bounded current user message")
        var stale = primary; stale.revision = 6; stale.status = .completed
        XCTAssertTrue(core.ingestPrimary(stale).isEmpty)
        primary.revision = 8; primary.status = .completed
        XCTAssertEqual(core.ingestPrimary(primary).first?.status, .completed)
        primary.revision = 9; primary.status = .running
        XCTAssertTrue(core.ingestPrimary(primary).isEmpty, "Same-turn terminal state cannot reopen")
    }

    func testDisconnectRevokesLiveStateWithoutInventingCompletionAndNewSourceCanRecover() {
        var core = CodexAgentState()
        let id = CodexAgentState.id(AgentFixtures.thread)
        var primary = CodexPrimarySnapshot(kind: .daemon, threadID: id.sessionID, turnID: "turn-1")
        primary.classification = .userSession; primary.title = "Fixture"; primary.status = .running
        primary.revision = 1; primary.activeToolName = "Bash"
        _ = core.ingestPrimary(primary)
        let lost = core.losePrimary(kind: .daemon, threads: [id.sessionID])
        XCTAssertEqual(lost.first?.status, .unknown)
        XCTAssertNil(core.snapshot.primaryChannels[id]); XCTAssertNil(core.snapshot.tools[id])
        XCTAssertEqual(core.ingestPrimary(primary).first?.status, .running)
        var internalRun = CodexPrimarySnapshot(kind: .daemon, threadID: "internal-fixture", turnID: "turn-x")
        internalRun.classification = .internalSuggestion
        XCTAssertTrue(core.ingestPrimary(internalRun).isEmpty)
        XCTAssertFalse(core.retainedSessionIDs.contains(CodexAgentState.id("internal-fixture")))
    }
}
