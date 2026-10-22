import Foundation
import Darwin
import XCTest
@testable import NotchX

@MainActor
final class CodexHookAutomationTests: XCTestCase {
    func testDefaultActivationNeverInstallsOrProbesHooksAndPreservesForeignConfiguration() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        let foreign = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}"#.utf8)
        try foreign.write(to: root.appendingPathComponent("hooks.json"))
        let requests = UnexpectedHookRequests()
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/echo"), request: { try await requests.request($0, $1) })
        automation.configure(active: true); await automation.finish()
        automation.refresh(); await automation.finish()
        automation.configure(active: false); await automation.finish()
        let count = await requests.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(config.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.helper.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), foreign)
        XCTAssertEqual(automation.state, .off)
    }

    func testExistingHooksAreDisabledByDefaultWithoutChangingDefinitionsOrTrust() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let definitions = try Data(contentsOf: root.appendingPathComponent("hooks.json"))
        let fixture = try HookControlFixture(configuration: config)
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/echo"), request: { try await fixture.request($0, $1) })
        automation.configure(active: true); await automation.finish()
        let flags = await fixture.flags
        XCTAssertTrue(flags.values.allSatisfy { !$0 })
        XCTAssertEqual(automation.state, .waitingForRefresh, "A daemon config write does not confirm Desktop refresh")
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config.runtimePolicyFile)) as? [String: Any])
        XCTAssertEqual(policy["enabled"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), definitions)
        let text = try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(text.contains("preserved-trust")); XCTAssertTrue(text.contains("foreign-trust"))
    }
    func testOwnedKeysAcceptOSPathAliasesButNeverSelectReorderedForeignHandlers() throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        let file = root.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "/foreign/helper"]]]]]]).write(to: file)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let physical = try XCTUnwrap(file.path.withCString { realpath($0, nil) })
        defer { free(physical) }
        let source = String(cString: physical)
        XCTAssertTrue(config.owns(key: source + ":pre_tool_use:1:0"))
        XCTAssertFalse(config.owns(key: source + ":pre_tool_use:0:0"))
        XCTAssertFalse(config.owns(key: root.appendingPathComponent("foreign.json").path + ":pre_tool_use:1:0"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var events = try XCTUnwrap(object["hooks"] as? [String: Any])
        events["PreToolUse"] = Array(try XCTUnwrap(events["PreToolUse"] as? [[String: Any]]).reversed())
        object["hooks"] = events
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        XCTAssertFalse(config.owns(key: source + ":pre_tool_use:1:0"), "A saved owned index must not select a foreign command after reorder")
        XCTAssertTrue(config.owns(key: source + ":pre_tool_use:0:0"))
    }

    func testReloadWritesOnlyOwnedEnablementAndRestoresOnLostCoverage() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let definitions = try Data(contentsOf: root.appendingPathComponent("hooks.json"))
        let fixture = try HookControlFixture(configuration: config)
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/echo"), request: { try await fixture.request($0, $1) })
        var snapshot = CodexPrimarySnapshot(kind: .daemon, threadID: AgentFixtures.thread)
        snapshot.classification = .userSession; snapshot.capabilities = [.lifecycle, .tools, .plans]
        automation.configure(active: true, fallbackEnabled: true, snapshots: [snapshot], activeThreads: [AgentFixtures.thread])
        await automation.finish()
        XCTAssertEqual(automation.state, .suspended)
        XCTAssertEqual(automation.suspendedEvents, Set(AgentHookEnvelope.events))
        let writes = await fixture.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.reload, true)
        let ownedKeys = await fixture.ownedToolKeys
        XCTAssertEqual(writes.first?.keys.count, ownedKeys.count)
        for key in ownedKeys { XCTAssertTrue(writes.first?.keys.contains(where: { $0.contains(key) }) == true) }
        XCTAssertFalse(writes.flatMap(\.keys).contains { $0.contains("trusted_hash") || $0.contains("foreign") })
        automation.configure(active: true, fallbackEnabled: true)
        await automation.finish()
        XCTAssertEqual(automation.state, .ready)
        let restored = await fixture.ownEnabled, foreign = await fixture.foreignEnabled
        XCTAssertTrue(restored)
        XCTAssertFalse(foreign)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), definitions)
        let text = try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(text.contains("trusted_hash = \"preserved-trust\""))
        automation.configure(active: false)
        await automation.finish()
        XCTAssertEqual(automation.state, .waitingForRefresh)
        let policy = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config.runtimePolicyFile)) as? [String: Any])
        XCTAssertEqual(policy["enabled"] as? Bool, false)
    }

    func testUserDisabledHookRemainsDisabledAndHelperUpdatesWithoutDefinitionRewrite() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let before = try Data(contentsOf: root.appendingPathComponent("hooks.json"))
        let fixture = try HookControlFixture(configuration: config, ownEnabled: false)
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/cat"), request: { try await fixture.request($0, $1) })
        automation.configure(active: true)
        await automation.finish()
        let enabled = await fixture.ownEnabled, writes = await fixture.writes
        XCTAssertFalse(enabled)
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(config.helperStatus(bundledHelper: URL(fileURLWithPath: "/bin/cat")), .current)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), before)
    }

    func testLostBackendRestoresPersistedFlagsButReportsRuntimeRefreshPending() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let fixture = try HookControlFixture(configuration: config)
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/echo"), request: { try await fixture.request($0, $1) })
        var primary = CodexPrimarySnapshot(kind: .daemon, threadID: AgentFixtures.thread)
        primary.classification = .userSession; primary.capabilities = [.lifecycle, .tools, .plans]
        automation.configure(active: true, fallbackEnabled: true, snapshots: [primary], activeThreads: [AgentFixtures.thread]); await automation.finish()
        await fixture.setUnavailable()
        automation.configure(active: true, fallbackEnabled: true); await automation.finish()
        XCTAssertEqual(automation.state, .waitingForRefresh)
        let text = try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "enabled = false").count - 1, 1, "Only the foreign disabled flag remains")
        XCTAssertTrue(text.contains("trusted_hash = \"preserved-trust\""))
    }

    func testDesktopAndDaemonCoverageSuspendHooksButNotForUncoveredLiveThreads() {
        var primary = CodexPrimarySnapshot(kind: .desktop, threadID: AgentFixtures.thread)
        primary.classification = .userSession; primary.capabilities = [.lifecycle, .tools, .plans]
        XCTAssertEqual(CodexHookAutomation.suspendableEvents(snapshots: [primary], activeThreads: [AgentFixtures.thread]), Set(AgentHookEnvelope.events))
        primary = CodexPrimarySnapshot(kind: .daemon, threadID: AgentFixtures.thread)
        primary.classification = .userSession; primary.capabilities = [.lifecycle, .tools, .plans]
        XCTAssertTrue(CodexHookAutomation.suspendableEvents(snapshots: [primary], activeThreads: ["uncovered-thread"]).isEmpty)
    }

    func testExplicitRemovalNeedsAnotherExplicitEnableIntent() async throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let fixture = try HookControlFixture(configuration: config)
        let automation = CodexHookAutomation(configuration: config, bundledHelper: URL(fileURLWithPath: "/bin/echo"), request: { try await fixture.request($0, $1) })
        automation.configure(active: true, fallbackEnabled: true); await automation.finish()
        automation.pauseInstallation()
        try config.remove()
        await automation.finish()
        automation.configure(active: true, fallbackEnabled: true); automation.refresh(); await automation.finish()
        XCTAssertFalse(config.isInstalled())
        XCTAssertEqual(automation.state, .off)
        automation.configure(active: false); await automation.finish()
        automation.configure(active: true, fallbackEnabled: true); await automation.finish()
        XCTAssertFalse(config.isInstalled(), "Restarting the provider cannot undo removal")
        automation.allowInstallation()
        automation.configure(active: true, fallbackEnabled: true); await automation.finish()
        XCTAssertTrue(config.isInstalled())
    }

    func testNarrowEditorPreservesTrustAndDoesNotEditHeadersInsideMultilineStrings() throws {
        let key = "/fixture/hooks.json:pre_tool_use:0:0"
        let original = "instructions = '''\n[hooks.state.\"\(key)\"]\nenabled = false\n'''\n[hooks.state.\"\(key)\"]\nenabled = false # keep comment\ntrusted_hash = \"preserve\"\n[hooks.state.foreign]\nenabled = false\n"
        let edited = String(decoding: try CodexHookConfigEditor.settingEnablement([key: true], in: Data(original.utf8)), as: UTF8.self)
        XCTAssertTrue(edited.contains("enabled = true # keep comment"))
        XCTAssertTrue(edited.contains("instructions = '''\n[hooks.state.\"\(key)\"]\nenabled = false\n'''"))
        XCTAssertTrue(edited.contains("[hooks.state.foreign]\nenabled = false"))
        XCTAssertTrue(edited.contains("trusted_hash = \"preserve\""))
        XCTAssertThrowsError(try CodexHookConfigEditor.settingEnablement([key: true], in: Data("[unrelated]\nenabled=false\n".utf8)))
    }
}

private actor UnexpectedHookRequests {
    var count = 0
    func request(_ method: String, _ data: Data) throws -> Data {
        count += 1
        throw AgentHookWireError.unavailable
    }
}

private actor HookControlFixture {
    struct Write: Sendable { let keys: [String]; let reload: Bool }
    let configuration: CodexHookConfiguration
    var ownEnabled: Bool
    var foreignEnabled = false
    var writes: [Write] = []
    var offline = false
    var version = 0
    var flags: [String: Bool] = [:]
    var ownedToolKeys: [String] { ["PreToolUse", "PostToolUse", "UserPromptSubmit"].map(key) }

    init(configuration: CodexHookConfiguration, ownEnabled: Bool = true) throws {
        self.configuration = configuration; self.ownEnabled = ownEnabled
        let path = configuration.root.appendingPathComponent("hooks.json").resolvingSymlinksInPath().path
        var text = ""
        for event in ["pre_tool_use", "post_tool_use", "user_prompt_submit"] {
            let key = path + ":" + event + ":0:0"
            flags[key] = ownEnabled
            text += "[hooks.state.\"\(key)\"]\nenabled = \(ownEnabled)\ntrusted_hash = \"preserved-trust\"\n"
        }
        text += "[hooks.state.foreign]\nenabled = false\ntrusted_hash = \"foreign-trust\"\n"
        try text.write(to: configuration.root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }
    func key(_ event: String) -> String {
        let snake = event.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
        return configuration.root.appendingPathComponent("hooks.json").resolvingSymlinksInPath().path + ":" + snake + ":0:0"
    }
    func setUnavailable() { offline = true }
    func request(_ method: String, _ bytes: Data) throws -> Data {
        if offline { throw AgentHookWireError.unavailable }
        let params = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let result: [String: Any]
        switch method {
        case "hooks/list":
            var hooks = ["PreToolUse", "PostToolUse", "UserPromptSubmit"].map { event -> [String: Any] in
                ["key": key(event), "currentHash": "definition-" + event, "enabled": flags[key(event)] ?? true,
                 "trustStatus": "trusted", "isManaged": false,
                 "eventName": event.prefix(1).lowercased() + event.dropFirst(), "command": configuration.command,
                 "sourcePath": configuration.root.appendingPathComponent("hooks.json").path]
            }
            hooks.append(["key": "foreign", "enabled": false, "command": "/foreign/helper", "sourcePath": "/foreign/hooks.json"])
            result = ["data": [["hooks": hooks]]]
        case "config/read":
            result = ["layers": [["name": ["type": "user", "file": configuration.root.appendingPathComponent("config.toml").path], "version": "v\(version)"]]]
        case "config/batchWrite":
            XCTAssertEqual(params["expectedVersion"] as? String, "v\(version)")
            let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
            var values: [String: Bool] = [:]
            for edit in edits {
                let path = try XCTUnwrap(edit["keyPath"] as? String)
                XCTAssertTrue(path.hasSuffix(".enabled")); XCTAssertFalse(path.contains("trusted_hash"))
                let quoted = String(path.dropFirst("hooks.state.".count).dropLast(".enabled".count))
                let key = try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
                XCTAssertTrue(configuration.owns(key: key))
                values[key] = try XCTUnwrap(edit["value"] as? Bool)
                flags[key] = values[key]
            }
            try configuration.writeOwnedEnablement(values)
            ownEnabled = flags[key("PreToolUse")] ?? true
            version += 1
            writes.append(Write(keys: edits.compactMap { $0["keyPath"] as? String }, reload: params["reloadUserConfig"] as? Bool ?? false))
            result = ["status": "ok", "version": "v\(version)"]
        default: throw AgentHookWireError.invalidMessage
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}
