import Foundation
import XCTest
@testable import NotchX

final class CodexNativeRequestTests: XCTestCase {
    func testQuestionResponseRequiresEveryOriginalQuestionAndBoundedAnswers() throws {
        let params: [String: Any] = ["questions": [
            ["id": "viewport", "header": "Viewport", "question": "Which viewport?", "isSecret": false,
             "options": [["label": "Desktop", "description": "Wide"]]],
            ["id": "credential", "header": "Credential", "question": "Fixture secret?", "isSecret": true]
        ]]
        let input = try XCTUnwrap(CodexNativeRequests.input(params: params, id: "native-input"))
        XCTAssertTrue(input.questions[1].isSecret)
        let id = CodexAgentState.id(AgentFixtures.thread)
        func response(_ answers: [String: [String]]) -> AgentInputResponse {
            AgentInputResponse(requestID: input.id, sessionID: id, turnID: "turn-1", answers: answers)
        }
        XCTAssertTrue(response(["viewport": ["Desktop"], "credential": ["fixture value"]]).matches(input))
        XCTAssertFalse(response(["viewport": ["Desktop"]]).matches(input))
        XCTAssertFalse(response(["viewport": ["Desktop"], "credential": [" "], "injected": ["answer"]]).matches(input))
        XCTAssertFalse(response(["viewport": [String(repeating: "a", count: 8_001)], "credential": ["fixture"]]).matches(input))
        var duplicate = params; duplicate["questions"] = Array(repeating: (params["questions"] as! [[String: Any]])[0], count: 2)
        XCTAssertNil(CodexNativeRequests.input(params: duplicate, id: "native-input"))
        var oversized = params; oversized["questions"] = Array(repeating: [:], count: 9)
        XCTAssertNil(CodexNativeRequests.input(params: oversized, id: "native-input"))
    }

    func testConcurrentNativeApprovalsResolveIndependentlyAndDisconnectRevokesThem() {
        let id = CodexAgentState.id(AgentFixtures.thread)
        func approval(_ request: String) -> AgentApproval {
            AgentApproval(id: request, sessionID: id, turnID: "turn-1", tool: "exec_command",
                command: "fixture " + request, reason: nil, expiresAt: .distantFuture)
        }
        var core = CodexAgentState()
        var snapshot = CodexPrimarySnapshot(kind: .desktop, threadID: id.sessionID, turnID: "turn-1")
        snapshot.classification = .userSession; snapshot.status = .waitingApproval
        snapshot.capabilities = [.lifecycle, .approvals]; snapshot.revision = 1
        snapshot.approvals = [approval("request-a"), approval("request-b")]
        _ = core.ingestPrimary(snapshot)
        XCTAssertEqual(core.snapshot.approvals.count, 2)
        XCTAssertTrue(core.beginDecision("request-a"))
        snapshot.revision = 2; snapshot.approvals = [approval("request-b")]
        _ = core.ingestPrimary(snapshot)
        XCTAssertEqual(core.snapshot.approvals.map(\.id), ["request-b"])
        _ = core.losePrimary(kind: .desktop, threads: [id.sessionID])
        XCTAssertTrue(core.snapshot.approvals.isEmpty)
        XCTAssertFalse(core.beginDecision("request-b"))
    }

    func testCommandApprovalNeverReinterpretsPermissionOrNetworkRequests() {
        var params: [String: Any] = ["threadId": AgentFixtures.thread, "turnId": "turn-1", "kind": "command",
            "command": "fixture command", "availableDecisions": ["decline"]]
        let request = CodexNativeRequests.approval(params: params, id: "command-1")
        XCTAssertEqual(request?.canAllow, false); XCTAssertEqual(request?.canDeny, true)
        params["networkApprovalContext"] = ["host": "fixture.invalid"]
        XCTAssertNil(CodexNativeRequests.approval(params: params, id: "network-1"))
        params.removeValue(forKey: "networkApprovalContext")
        params["additionalPermissions"] = ["fileSystem": [:]]
        XCTAssertNil(CodexNativeRequests.approval(params: params, id: "permissions-1"))
    }
}
