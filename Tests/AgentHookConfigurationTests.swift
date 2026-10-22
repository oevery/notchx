import Foundation
import XCTest
@testable import NotchX

final class AgentHookConfigurationTests: XCTestCase {
    func testHelperRepairDetectsStaleAndMissingVersionsWithoutRewritingHooksOrTrust() throws {
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: "/fixture.sock")
        let first = URL(fileURLWithPath: "/bin/echo"), replacement = URL(fileURLWithPath: "/bin/cat")
        XCTAssertEqual(config.helperStatus(bundledHelper: first), .missing)
        XCTAssertThrowsError(try config.updateHelper(bundledHelper: first), "Repair cannot silently install hook entries")
        try config.install(bundledHelper: first)
        XCTAssertEqual(config.helperStatus(bundledHelper: first), .current)
        XCTAssertEqual(config.helperStatus(bundledHelper: replacement), .outdated)
        let hooks = root.appendingPathComponent("hooks.json")
        let bytes = try Data(contentsOf: hooks)
        let inventory = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try config.updateHelper(bundledHelper: replacement)
        XCTAssertEqual(config.helperStatus(bundledHelper: replacement), .current)
        XCTAssertEqual(try Data(contentsOf: hooks), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), inventory.sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path))
        try FileManager.default.removeItem(at: config.helper)
        XCTAssertEqual(config.helperStatus(bundledHelper: replacement), .missing)
        try config.updateHelper(bundledHelper: replacement)
        XCTAssertEqual(config.helperStatus(bundledHelper: replacement), .current)
        let permissions = try FileManager.default.attributesOfItem(atPath: config.helper.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        try FileManager.default.removeItem(at: config.helper)
        try FileManager.default.createSymbolicLink(at: config.helper, withDestinationURL: replacement)
        XCTAssertEqual(config.helperStatus(bundledHelper: replacement), .unavailable)
        XCTAssertThrowsError(try config.updateHelper(bundledHelper: replacement))
        XCTAssertEqual(try Data(contentsOf: hooks), bytes)
    }

    func testInstallAndRemovePreserveForeignHooksAndAreIdempotent() throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = CodexHookConfiguration(root: root, helper: directory.appendingPathComponent("managed/helper"),
            socketPath: directory.appendingPathComponent("events.sock").path)
        let foreign: [String: Any] = ["description": "Existing fixture", "hooks": ["Stop": [["matcher": "fixture",
            "hooks": [["type": "command", "command": "/fixture/foreign-helper", "timeout": 7]]]]]]
        let file = root.appendingPathComponent("hooks.json")
        try AgentFixtures.json(foreign).write(to: file)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        XCTAssertTrue(config.isInstalled())
        let first = try Data(contentsOf: file)
        try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        XCTAssertEqual(try Data(contentsOf: file), first)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("backup") }
        XCTAssertEqual(backups.count, 1)
        try config.remove()
        XCTAssertFalse(config.isInstalled())
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
        XCTAssertEqual(restored, foreign as NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path), "Must not edit the trust ledger")
    }

    func testManagedSymlinkAndMalformedConfigurationAreNotOverwritten() throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("managed.json")
        let original = Data("{}".utf8)
        try original.write(to: target)
        let link = directory.appendingPathComponent("hooks.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let config = CodexHookConfiguration(root: directory, helper: directory.appendingPathComponent("helper"), socketPath: "/fixture.sock")
        XCTAssertThrowsError(try config.install(bundledHelper: URL(fileURLWithPath: "/bin/echo")))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertThrowsError(try config.merged(existing: Data(#"{"hooks":[]}"#.utf8), installing: true))
    }

    func testPreviewUsesQuotedPathsAndSeparateApprovalDeadline() throws {
        let directory = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = CodexHookConfiguration(root: directory, helper: directory.appendingPathComponent("a 'quoted' helper"), socketPath: "/fixture.sock")
        let preview = try config.preview()
        XCTAssertTrue(preview.contains("PermissionRequest"))
        XCTAssertTrue(preview.contains("125"))
        XCTAssertTrue(config.command.contains("'\"'\"'"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hooks.json").path))
    }
}
