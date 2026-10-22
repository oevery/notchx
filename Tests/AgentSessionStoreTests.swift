import Foundation
import XCTest
@testable import NotchX

final class AgentSessionStoreTests: XCTestCase {
    private func event(_ session: String = "s", provider: String = "codex.fixture", run: String? = "run-1",
                       request: String? = nil, eventID: String? = nil, sequence: Int64 = 1,
                       parent: String? = nil, classification: AgentSourceClassification = .userSession,
                       status: AgentActivityStatus = .running, timestamp: TimeInterval = 1) -> AgentSessionEvent {
        AgentSessionEvent(id: AgentSessionID(providerID: provider, sessionID: session),
            runID: run, requestID: request, eventID: eventID ?? "e-\(sequence)", sequence: sequence,
            parentID: parent.map { AgentSessionID(providerID: provider, sessionID: $0) },
            classification: classification, status: status, title: "Fixture session", summary: "Read-only example",
            updatedAt: Date(timeIntervalSince1970: timestamp))
    }

    func testIdentityNamespacesAndRequestIDsAreSeparate() {
        var store = AgentSessionStore()
        XCTAssertTrue(store.ingest(event(request: "approval-1", status: .waitingApproval)))
        XCTAssertTrue(store.ingest(event(provider: "other-account", request: "approval-1", status: .waitingInput)))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.attentionCount, 2)
        XCTAssertEqual(store.rootSessions.first?.runID, "run-1")
        XCTAssertEqual(store.rootSessions.first?.requestID, "approval-1")
    }

    func testReplayAndOutOfOrderEventsCannotRevertState() {
        var store = AgentSessionStore(maxReplayEvents: 1)
        XCTAssertTrue(store.ingest(event(sequence: 2, status: .waitingInput, timestamp: 2)))
        XCTAssertFalse(store.ingest(event(sequence: 2, status: .completed, timestamp: 3)))
        XCTAssertFalse(store.ingest(event(sequence: 1, timestamp: 100)))
        XCTAssertFalse(store.ingest(event(eventID: "e-2", sequence: 3, status: .completed)))
        XCTAssertEqual(store.rootSessions.first?.status, .waitingInput)
    }

    func testTerminalRunAndLatePreviousRunCannotRestart() {
        var store = AgentSessionStore()
        XCTAssertTrue(store.ingest(event(status: .cancelled)))
        XCTAssertFalse(store.ingest(event(sequence: 2, status: .running)))
        XCTAssertFalse(store.ingest(event(run: nil, sequence: 3)))
        XCTAssertTrue(store.ingest(event(run: "run-2", sequence: 4, timestamp: 0)))
        XCTAssertFalse(store.ingest(event(sequence: 3, status: .waitingApproval, timestamp: 100)))
        XCTAssertEqual(store.rootSessions.first?.runID, "run-2")
        XCTAssertEqual(store.rootSessions.first?.status, .running)
    }

    func testInternalUnknownAndOrphanChildrenDoNotCreateAttention() {
        var store = AgentSessionStore()
        store.ingest(event("suggestion", classification: .internalSuggestion, status: .waitingInput))
        store.ingest(event("unknown", classification: .unknown, status: .waitingApproval))
        store.ingest(event("orphan", parent: "missing", classification: .subagent, status: .waitingApproval))
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertTrue(store.rootSessions.isEmpty)
        XCTAssertEqual(store.attentionCount, 0)
    }

    func testUnknownProvenanceCannotEraseVerifiedRoot() {
        var store = AgentSessionStore()
        store.ingest(event(status: .waitingInput))
        XCTAssertFalse(store.ingest(event(sequence: 2, classification: .unknown, status: .running)))
        XCTAssertEqual(store.attentionCount, 1)
        XCTAssertEqual(store.rootSessions.first?.classification, .userSession)
        XCTAssertTrue(store.ingest(event(sequence: 3, status: .unknown)))
        XCTAssertEqual(store.attentionCount, 0)
    }

    func testNestedChildrenAggregateOnceAndTerminalRootWins() {
        var store = AgentSessionStore()
        store.ingest(event("root"))
        store.ingest(event("child", parent: "root", classification: .subagent, status: .waitingInput))
        store.ingest(event("nested", parent: "child", classification: .subagent, status: .waitingApproval))
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.children.count, 2)
        XCTAssertEqual(store.groups.first?.status, .waitingApproval)
        XCTAssertEqual(store.attentionCount, 1)
        store.ingest(event("root", sequence: 2, status: .completed))
        XCTAssertEqual(store.attentionCount, 0)
        XCTAssertEqual(store.groups.first?.status, .completed)
    }

    func testCyclesAndInvalidParentingCannotBecomeVisibleRoots() {
        var store = AgentSessionStore()
        XCTAssertFalse(store.ingest(event(parent: "s")))
        store.ingest(event("a", parent: "b", classification: .subagent))
        store.ingest(event("b", parent: "a", classification: .subagent, status: .waitingApproval))
        XCTAssertTrue(store.groups.isEmpty)
        let crossProvider = AgentSessionEvent(id: AgentSessionID(providerID: "a", sessionID: "cross"),
            runID: "run", requestID: nil, eventID: "cross", sequence: 1,
            parentID: AgentSessionID(providerID: "b", sessionID: "parent"), classification: .subagent,
            status: .running, title: "", summary: nil, updatedAt: Date())
        XCTAssertFalse(store.ingest(crossProvider))
    }

    func testEventIDsMayRepeatInDifferentRunsAndSessions() {
        var store = AgentSessionStore()
        XCTAssertTrue(store.ingest(event("one", eventID: "same", status: .completed)))
        XCTAssertTrue(store.ingest(event("one", run: "run-2", eventID: "same", sequence: 2)))
        XCTAssertTrue(store.ingest(event("two", eventID: "same")))
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testVerifiedTransitionsAndTerminalStates() {
        for terminal in [AgentActivityStatus.completed, .failed, .cancelled] {
            var store = AgentSessionStore()
            store.ingest(event())
            XCTAssertEqual(store.attentionCount, 0)
            store.ingest(event(request: "input", sequence: 2, status: .waitingInput))
            XCTAssertEqual(store.attentionCount, 1)
            store.ingest(event(request: "approval", sequence: 3, status: .waitingApproval))
            XCTAssertEqual(store.attentionCount, 1)
            store.ingest(event(sequence: 4, status: terminal))
            XCTAssertEqual(store.attentionCount, 0)
            XCTAssertEqual(store.rootSessions.first?.status, terminal)
        }
    }

    func testAuthoritativeInventoryPrunesArchivedSessionsAndTheirReplayKeys() {
        var store = AgentSessionStore()
        let kept = event("kept", status: .waitingInput)
        let archived = event("archived", status: .waitingApproval)
        let deleted = event("deleted", parent: "archived", classification: .subagent)
        store.ingest(kept)
        store.ingest(archived)
        store.ingest(deleted)
        XCTAssertEqual(store.attentionCount, 2)
        store.retainSessions([kept.id])
        XCTAssertEqual(Set(store.sessions.keys), [kept.id])
        XCTAssertEqual(store.attentionCount, 1)
        XCTAssertFalse(store.ingest(kept), "Retained replay identity stays deduplicated")
        XCTAssertTrue(store.ingest(archived), "Pruned replay identity can be reintroduced by the source")
        store.retainSessions([])
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.attentionCount, 0)
        XCTAssertTrue(store.ingest(kept))
    }

    func testRetentionAndResetAreBoundedAndDeterministic() {
        var store = AgentSessionStore(maxSessions: 2, maxReplayEvents: 2)
        store.ingest(event("old", timestamp: 1))
        store.ingest(event("middle", timestamp: 2))
        store.ingest(event("new", timestamp: 3))
        XCTAssertEqual(store.rootSessions.map { $0.id.sessionID }, ["new", "middle"])
        store.reset()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.attentionCount, 0)
        XCTAssertTrue(store.ingest(event("new", timestamp: 3)))
    }
}
