import Foundation
import XCTest
@testable import NotchX

@MainActor
final class CodexLiveStatusSourceTests: XCTestCase {
    func testProviderSwitchStopsRealSocketObserversAndRefreshJobButKeepsHooks() async throws {
        let root = try AgentFixtures.directory(), path = root.appendingPathComponent("provider.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path)
        let manager = AgentManager(sourceFactory: { source })
        manager.setCodexHookFallbackEnabled(true)
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let configuration = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: path)
        try configuration.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let hooks = try Data(contentsOf: root.appendingPathComponent("hooks.json"))
        let file = try makeTranscript(root: root)
        manager.setEnabled(true)
        XCTAssertTrue(AgentUnixSocket.ownedSocket(path))
        XCTAssertTrue(ModuleRefreshScheduler.shared.diagnostics.contains { $0.id == "agent.codex.readonly" })
        _ = try await invoke("UserPromptSubmit", transcript: file, path: path, root: root, fields: ["prompt": "Provider fixture"])
        try await NativeUI.waitFor("provider observer started") { manager.interaction.liveObserverCount == 1 }
        let pending = Task {
            try await invoke("PermissionRequest", transcript: file, path: path, root: root,
                fields: ["tool_name": "Bash", "permission_mode": "default", "tool_input": ["command": "echo fixture"]])
        }
        try await NativeUI.waitFor("provider pending hook") { manager.interaction.approvals.count == 1 }
        manager.setCodexEnabled(false)
        let output = try await pending.value
        XCTAssertEqual(output.output, "{}\n")
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
        XCTAssertFalse(ModuleRefreshScheduler.shared.diagnostics.contains { $0.id == "agent.codex.readonly" })
        XCTAssertTrue(manager.groups.isEmpty); XCTAssertEqual(manager.interaction.liveObserverCount, 0)
        XCTAssertTrue(manager.interaction.approvals.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        var progress = try AgentFixtures.json(["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary",
            "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            "content": [["type": "output_text", "text": "Disabled fixture progress"]]]])
        progress.append(10); try handle.write(contentsOf: progress); try handle.close()
        await NativeUI.drainMainQueue()
        XCTAssertTrue(manager.groups.isEmpty); XCTAssertEqual(manager.interaction.liveProgressUpdates, 0)
        manager.setEnabled(false); manager.setEnabled(true)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
        XCTAssertFalse(ModuleRefreshScheduler.shared.diagnostics.contains { $0.id == "agent.codex.readonly" })
        manager.setCodexEnabled(true)
        XCTAssertTrue(AgentUnixSocket.ownedSocket(path))
        XCTAssertTrue(ModuleRefreshScheduler.shared.diagnostics.contains { $0.id == "agent.codex.readonly" })
        XCTAssertEqual(manager.interaction.liveObserverCount, 0, "Old progress cannot be restored on re-enable")
        _ = try await invoke("UserPromptSubmit", transcript: file, path: path, root: root, fields: ["prompt": "Fresh provider fixture"])
        try await NativeUI.waitFor("provider observer restarts after a verified event") { manager.interaction.liveObserverCount == 1 }
        XCTAssertNil(manager.interaction.contexts[CodexAgentState.id(AgentFixtures.thread)]?.progressText)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), hooks)
        manager.setEnabled(false)
    }

    func testNewPublicProgressAndAsyncQuestionsReachOriginalSessionWithoutHistoryBackfill() async throws {
        let root = try AgentFixtures.directory(), path = root.appendingPathComponent("live.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path)
        let manager = AgentManager(sourceFactory: { source })
        manager.setCodexHookFallbackEnabled(true)
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let file = try makeTranscript(root: root), id = CodexAgentState.id(AgentFixtures.thread)
        func append(_ type: String, _ payload: [String: Any]) throws {
            var bytes = try AgentFixtures.json(["type": type, "payload": payload]); bytes.append(10)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        }
        let publicRecord: [String: Any] = ["type": "message", "role": "assistant", "phase": "commentary",
            "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            "content": [["type": "output_text", "text": "Checking the current viewport"]]]
        try append("response_item", publicRecord)
        manager.setEnabled(true)
        _ = try await invoke("UserPromptSubmit", transcript: file, path: path, root: root, fields: ["prompt": "Fixture live progress"])
        try await NativeUI.waitFor("verified observer ready") { manager.interaction.liveObserverCount == 1 }
        XCTAssertNil(manager.interaction.contexts[id]?.progressText, "No historical content is restored")
        try append("response_item", publicRecord)
        try await NativeUI.waitFor("new public progress") { manager.interaction.contexts[id]?.progressText == "Checking the current viewport" }
        let arguments = try AgentFixtures.json(["questions": [["title": "Which viewport should I check?"]]])
        try append("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "question-1",
            "arguments": String(decoding: arguments, as: UTF8.self)])
        try await NativeUI.waitFor("question attention in original session") { manager.groups.first?.status == .waitingInput && manager.attentionRequestID?.hasPrefix("input-") == true }
        XCTAssertEqual(manager.groups.count, 1); XCTAssertEqual(manager.panel.route, .detail(id))
        try append("response_item", ["type": "function_call_output", "call_id": "question-1", "output": "accepted"])
        try append("response_item", publicRecord)
        try await NativeUI.waitFor("async output processed") { manager.interaction.liveProgressUpdates >= 3 }
        XCTAssertNotNil(manager.interaction.contexts[id]?.pendingInput)
        try append("event_msg", ["type": "user_message"])
        try await NativeUI.waitFor("answer clears attention") { manager.interaction.contexts[id]?.pendingInput == nil && manager.groups.first?.status == .running }
        try append("event_msg", ["type": "task_complete", "turn_id": "turn-1"])
        try await NativeUI.waitFor("observer closes at end") { manager.interaction.liveObserverCount == 0 && manager.groups.first?.status == .completed }
        XCTAssertEqual(manager.interaction.eventCounts["UserPromptSubmit"], 1)
        manager.setEnabled(false)
        try append("response_item", publicRecord)
        await NativeUI.drainMainQueue()
        XCTAssertTrue(manager.groups.isEmpty); XCTAssertEqual(manager.interaction.liveProgressUpdates, 0)
    }

    func testBundledBridgeDeliversConcurrentProgressAndPostToolPlanToManager() async throws {
        let root = try AgentFixtures.directory(), path = root.appendingPathComponent("progress.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path)
        let manager = AgentManager(sourceFactory: { source })
        manager.setCodexHookFallbackEnabled(true)
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let transcript = try makeTranscript(root: root), id = CodexAgentState.id(AgentFixtures.thread)
        manager.setEnabled(true)
        _ = try await invoke("UserPromptSubmit", transcript: transcript, path: path, root: root, fields: ["prompt": "Fixture progress"])
        _ = try await invoke("PreToolUse", transcript: transcript, path: path, root: root, fields: [
            "tool_use_id": "build", "tool_name": "Bash", "tool_input": ["command": "swift build"]])
        try await NativeUI.waitFor("shell action through helper and manager") { manager.interaction.tools[id] == "Bash" }
        XCTAssertEqual(manager.interaction.contexts[id]?.toolDetail, "swift build")
        _ = try await invoke("PreToolUse", transcript: transcript, path: path, root: root, fields: [
            "tool_use_id": "read", "tool_name": "mcp__fixture__read", "tool_input": ["path": "App/Views/CompactView.swift"]])
        _ = try await invoke("PostToolUse", transcript: transcript, path: path, root: root, fields: [
            "tool_use_id": "build", "tool_name": "Bash", "tool_input": ["command": "swift build"]])
        try await NativeUI.waitFor("parallel tool retained") { manager.interaction.tools[id] == "mcp__fixture__read" }
        XCTAssertEqual(manager.interaction.contexts[id]?.toolDetail, "App/Views/CompactView.swift")
        _ = try await invoke("PostToolUse", transcript: transcript, path: path, root: root, fields: [
            "tool_use_id": "read", "tool_name": "mcp__fixture__read", "tool_input": ["path": "App/Views/CompactView.swift"]])
        try await NativeUI.waitFor("completed tool kept as recent") { manager.interaction.contexts[id]?.lastCompletedTool?.name == "mcp__fixture__read" }
        _ = try await invoke("PostToolUse", transcript: transcript, path: path, root: root, fields: [
            "tool_use_id": "plan", "tool_name": "update_plan",
            "tool_input": ["plan": [["step": "Verify layout", "status": "in_progress"]]]])
        try await NativeUI.waitFor("plan from post-tool payload") { manager.interaction.contexts[id]?.plan.first?.step == "Verify layout" }
        XCTAssertEqual(manager.interaction.eventCounts["PreToolUse"], 2)
        XCTAssertEqual(manager.interaction.eventCounts["PostToolUse"], 3)
        XCTAssertEqual(manager.groups.count, 1)
        _ = try await invoke("Stop", transcript: transcript, path: path, root: root)
        try await NativeUI.waitFor("finished progress cleared") { manager.groups.first?.status == .completed }
        XCTAssertNil(manager.interaction.contexts[id]?.lastCompletedTool)
    }

    func testBridgeApprovalNavigationAndSuggestionClassificationWithoutSending() async throws {
        let root = try AgentFixtures.directory()
        let path = root.appendingPathComponent("hook.sock").path
        let archiveFile = root.appendingPathComponent("drafts.json")
        let savedDraft = Data("preserve existing drafts without reading or rewriting".utf8)
        try savedDraft.write(to: archiveFile)
        let source = CodexLiveStatusSource(root: root, socketPath: path, channels: [])
        let manager = AgentManager(sourceFactory: { source })
        manager.setCodexHookFallbackEnabled(true)
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let transcript = try makeTranscript(root: root)
        manager.setEnabled(true)
        _ = try await invoke("UserPromptSubmit", transcript: transcript, path: path, root: root,
                             fields: ["prompt": "Fixture workflow"])
        try await NativeUI.waitFor("verified live session") { manager.groups.first?.status == .running }
        let id = CodexAgentState.id(AgentFixtures.thread)
        XCTAssertEqual(manager.navigationTargets[id]?.url?.absoluteString, "codex://threads/" + AgentFixtures.thread)
        XCTAssertEqual(manager.groups.first?.root.title, "Fixture workflow")
        manager.selectSession(id)

        let approval = Task {
            try await invoke("PermissionRequest", transcript: transcript, path: path, root: root,
                fields: ["tool_name": "Bash", "permission_mode": "default", "tool_input": ["command": "echo fixture"]])
        }
        try await NativeUI.waitFor("live approval") { manager.interaction.approvals.count == 1 }
        let requestID = try XCTUnwrap(manager.interaction.approvals.first?.id)
        XCTAssertEqual(manager.attentionCount, 1)
        manager.respondToApproval(requestID, decision: .allow)
        manager.respondToApproval(requestID, decision: .allow)
        let output = try await approval.value
        XCTAssertTrue(output.output.contains("allow"))
        try await NativeUI.waitFor("consumed approval") { manager.interaction.approvals.isEmpty }

        let suggestions = #"{"suggestions":[{"title":"Regression","description":"Test cancellation"}]}"#
        _ = try await invoke("Stop", transcript: transcript, path: path, root: root, fields: ["last_assistant_message": suggestions])
        try await NativeUI.waitFor("suggestion classified without creating a task") { manager.interaction.eventCounts["Stop"] == 1 }
        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.selectedSessionID, id)
        XCTAssertTrue(manager.interaction.suggestions.isEmpty)
        XCTAssertNil(manager.interaction.primaryCapabilities[id], "Hook-only activity must not grant primary write capabilities")
        manager.refreshConnection()
        manager.setEnabled(false)
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertTrue(manager.interaction.approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archiveFile), savedDraft)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
    }

    func testDisableDefersRealPendingHookAndClearsSelection() async throws {
        let root = try AgentFixtures.directory()
        let path = root.appendingPathComponent("hook.sock").path
        let source = CodexLiveStatusSource(root: root, socketPath: path)
        let manager = AgentManager(sourceFactory: { source })
        manager.setCodexHookFallbackEnabled(true)
        defer { manager.setEnabled(false); try? FileManager.default.removeItem(at: root) }
        let transcript = try makeTranscript(root: root)
        manager.setEnabled(true)
        let pending = Task {
            try await invoke("PermissionRequest", transcript: transcript, path: path, root: root,
                fields: ["tool_name": "Bash", "permission_mode": "default", "tool_input": ["command": "echo fixture"]])
        }
        try await NativeUI.waitFor("pending approval") { manager.interaction.approvals.count == 1 }
        manager.selectSession(CodexAgentState.id(AgentFixtures.thread))
        manager.setEnabled(false)
        let output = try await pending.value
        XCTAssertEqual(output.output, "{}\n")
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertNil(manager.selectedSessionID)
    }

    private func makeTranscript(root: URL) throws -> URL {
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.jsonl")
        var bytes = try AgentFixtures.json(["type": "session_meta",
            "payload": ["id": AgentFixtures.thread, "thread_source": "user"]])
        bytes.append(10)
        bytes.append(try AgentFixtures.json(["type": "turn_context",
            "payload": ["turn_id": "turn-1", "approvals_reviewer": "user"]]))
        bytes.append(10)
        try bytes.write(to: file)
        return file
    }

    private func invoke(_ event: String, transcript: URL, path: String, root: URL,
                        fields: [String: Any] = [:]) async throws -> (status: Int32, output: String) {
        var object: [String: Any] = ["hook_event_name": event, "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "transcript_path": transcript.path]
        object.merge(fields) { _, new in new }
        return try await AgentHookTransportTests.invokeBridge(input: AgentFixtures.json(object), path: path, root: root)
    }
}
