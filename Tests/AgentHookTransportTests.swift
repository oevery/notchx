import Foundation
import Darwin
import XCTest
@testable import NotchX

final class AgentHookTransportTests: XCTestCase {
    func testRealSocketRoundTripAndSingleOwner() async throws {
        let directory = try AgentFixtures.directory()
        let path = directory.appendingPathComponent("events.sock").path
        let server = AgentHookServer(path: path)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start(receive: { event in server.respond(id: event.id, decision: .received) }, closed: { _ in })
        XCTAssertTrue(AgentUnixSocket.ownedSocket(path))
        let other = AgentHookServer(path: path)
        XCTAssertThrowsError(try other.start(receive: { _ in }, closed: { _ in }))
        let event = AgentFixtures.envelope("UserPromptSubmit")
        let reply = try await Task.detached { try AgentUnixSocket.exchange(event, path: path, timeout: 2) }.value
        XCTAssertEqual(reply.id, event.id)
        XCTAssertEqual(reply.decision, .received)
    }

    func testDisableUnblocksPendingApprovalWithNeutralResponse() async throws {
        let directory = try AgentFixtures.directory()
        let path = directory.appendingPathComponent("events.sock").path
        let server = AgentHookServer(path: path)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let arrived = expectation(description: "approval received")
        try server.start(receive: { _ in arrived.fulfill() }, closed: { _ in })
        let event = AgentFixtures.approval()
        let pending = Task.detached { try AgentUnixSocket.exchange(event, path: path, timeout: 3) }
        await fulfillment(of: [arrived], timeout: 2)
        server.stop()
        let reply = try await pending.value
        XCTAssertEqual(reply.decision, .deferToApp)
        XCTAssertFalse(AgentUnixSocket.ownedSocket(path))
    }

    func testClientDisconnectReleasesRequestAndTimeoutIsBounded() async throws {
        let directory = try AgentFixtures.directory()
        let path = directory.appendingPathComponent("events.sock").path
        let server = AgentHookServer(path: path)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let closed = expectation(description: "disconnected request closed")
        try server.start(receive: { _ in }, closed: { _ in closed.fulfill() })
        let event = AgentFixtures.approval()
        do {
            _ = try await Task.detached { try AgentUnixSocket.exchange(event, path: path, timeout: 0.15) }.value
            XCTFail("Expected bounded client timeout")
        } catch {}
        await fulfillment(of: [closed], timeout: 2)
    }

    func testUnsafeSocketDirectoryIsRejected() throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let server = AgentHookServer(path: directory.appendingPathComponent("events.sock").path)
        XCTAssertThrowsError(try server.start(receive: { _ in }, closed: { _ in }))
    }

    func testBundledBridgeIsNeutralWithoutAppAndNeverApprovesNonPermissionEvents() async throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("events.sock").path
        let input = try AgentFixtures.json(["hook_event_name": "Stop", "session_id": AgentFixtures.thread, "turn_id": "turn-1"])
        let absent = try await Self.invokeBridge(input: input, path: path, root: directory)
        XCTAssertEqual(absent.status, 0)
        XCTAssertEqual(absent.output, "{}\n")
        let server = AgentHookServer(path: path)
        defer { server.stop() }
        try server.start(receive: { event in server.respond(id: event.id, decision: .allow) }, closed: { _ in })
        let received = try await Self.invokeBridge(input: input, path: path, root: directory)
        XCTAssertEqual(received.output, "{}\n", "A reply cannot change Stop into permission approval")
    }

    func testBundledBridgeReturnsDocumentedPermissionDecision() async throws {
        let directory = try AgentFixtures.directory()
        let path = directory.appendingPathComponent("events.sock").path
        let server = AgentHookServer(path: path)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start(receive: { event in server.respond(id: event.id, decision: .deny) }, closed: { _ in })
        let input = try AgentFixtures.json(["hook_event_name": "PermissionRequest", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "tool_name": "Bash", "tool_input": ["command": "echo fixture"]])
        let reply = try await Self.invokeBridge(input: input, path: path, root: directory)
        let object = try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any]
        let specific = object?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual((specific?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    func testDisabledManagedBridgeReturnsNeutralBeforeConnecting() async throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = CodexHookConfiguration(root: directory, helper: directory.appendingPathComponent("managed/helper"), socketPath: directory.appendingPathComponent("events.sock").path)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchXAgentBridge")
        try config.install(bundledHelper: bundled)
        try config.setRuntimeEnabled(false)
        let server = AgentHookServer(path: config.socketPath)
        let received = expectation(description: "disabled helper must not connect")
        received.isInverted = true
        try server.start(receive: { _ in received.fulfill() }, closed: { _ in })
        defer { server.stop() }
        let input = try AgentFixtures.json(["hook_event_name": "UserPromptSubmit", "session_id": AgentFixtures.thread,
            "turn_id": "turn-1", "prompt": "disabled bridge fixture"])
        let result = try await Self.invokeBridge(input: input, path: config.socketPath, root: directory, helper: config.helper)
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.output, "{}\n")
        await fulfillment(of: [received], timeout: 0.1)
    }

    static func invokeBridge(input: Data, path: String, root: URL, helper suppliedHelper: URL? = nil) async throws -> (status: Int32, output: String) {
        let helper = suppliedHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchXAgentBridge")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        return try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = helper
            process.arguments = ["--socket", path, "--codex-home", root.path]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
            try stdout.fileHandleForReading.close()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }.value
    }
}
