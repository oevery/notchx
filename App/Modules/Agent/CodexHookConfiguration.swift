import Foundation
import Darwin

enum CodexHookConfigurationError: Error { case unsafeFile, invalidConfiguration, missingHelper, configurationChanged }
enum CodexHelperStatus: Equatable, Sendable { case missing, current, outdated, unavailable }

/// Owns only NotchX definitions and its bundled helper. Automatic management
/// never approves a definition or changes another integration's hooks.
struct CodexHookConfiguration: Sendable {
    let root: URL
    let helper: URL
    let socketPath: String

    static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(root: home.appendingPathComponent(".codex"),
            helper: home.appendingPathComponent("Library/Application Support/NotchX/Agent/NotchXAgentBridge"),
            socketPath: AgentUnixSocket.defaultPath)
    }

    private var file: URL { root.appendingPathComponent("hooks.json") }
    var runtimePolicyFile: URL { helper.appendingPathExtension("policy.json") }
    private var commandPrefix: String { Self.quote(helper.path) + " --socket " }
    var command: String {
        commandPrefix + Self.quote(socketPath) + " --codex-home " + Self.quote(root.path)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    func preview() throws -> String {
        let patch = try merged(existing: Data("{}".utf8), installing: true)
        return String(decoding: patch, as: UTF8.self)
    }

    func isInstalled() -> Bool {
        guard let data = try? read(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        let complete = AgentHookEnvelope.events.allSatisfy { name in
            guard let groups = hooks[name] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    $0["command"] as? String == command && $0["type"] as? String == "command"
                        && $0["timeout"] as? Int == Self.timeout(for: name)
                } == true
            }
        }
        let obsolete = hooks.contains { name, value in
            guard !AgentHookEnvelope.events.contains(name), let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.hasPrefix(commandPrefix) == true
                } == true
            }
        }
        return complete && !obsolete
    }

    func hasOwnedHooks() -> Bool {
        guard let data = try? read(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.hasPrefix(commandPrefix) == true
                } == true
            } == true
        }
    }

    func install(bundledHelper: URL) throws {
        let existing = try read()
        let updated = try merged(existing: existing, installing: true)
        try replaceHelper(bundledHelper)
        try write(updated, replacing: existing)
    }

    func helperStatus(bundledHelper: URL) -> CodexHelperStatus {
        do {
            try rejectSymlink(helper)
            guard FileManager.default.fileExists(atPath: helper.path) else { return .missing }
            let source = try helperData(bundledHelper)
            let installed = try helperData(helper)
            return source == installed ? .current : .outdated
        } catch { return .unavailable }
    }

    /// Explicit repair updates only our executable, preserving hooks and trust.
    func updateHelper(bundledHelper: URL) throws {
        guard isInstalled() else { throw CodexHookConfigurationError.invalidConfiguration }
        try replaceHelper(bundledHelper)
    }

    /// This immediate master gate complements Codex runtime refresh. A disabled
    /// integration does not enrich metadata or open a connection, even when an
    /// older Codex runtime still has the command registered.
    func setRuntimeEnabled(_ enabled: Bool) throws {
        let directory = helper.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try rejectSymlink(runtimePolicyFile)
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "enabled": enabled], options: [.sortedKeys])
        if (try? Data(contentsOf: runtimePolicyFile)) == bytes { return }
        try bytes.write(to: runtimePolicyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimePolicyFile.path)
    }

    func owns(command value: String, sourcePath: String?) -> Bool {
        guard value == command, let sourcePath else { return false }
        return URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
            == file.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Validate saved keys against the current definition before restoring them
    /// offline. Hook keys contain array indexes; an old index must never select
    /// a foreign command after another editor reorders the source file.
    func owns(key: String) -> Bool {
        // Codex's realpath keys can retain /private while Foundation removes
        // that alias. Parse indexes from the right (paths can contain colons),
        // normalize only the source path, and preserve the original state key.
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, let group = Int(parts[parts.count - 2]),
              let handler = Int(parts[parts.count - 1]), group >= 0, handler >= 0 else { return false }
        let source = parts.dropLast(3).joined(separator: ":")
        guard source.hasPrefix("/"),
              URL(fileURLWithPath: source).resolvingSymlinksInPath().standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
              let bytes = try? read(),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let events = object["hooks"] as? [String: Any] else { return false }
        for name in AgentHookEnvelope.events {
            let snake = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            guard snake == parts[parts.count - 3], let groups = events[name] as? [[String: Any]], groups.indices.contains(group),
                  let handlers = groups[group]["hooks"] as? [[String: Any]], handlers.indices.contains(handler) else { continue }
            return handlers[handler]["command"] as? String == command
        }
        return false
    }

    /// Restore only enablement values previously changed by NotchX. This does
    /// not claim active sessions reloaded them; the caller reports pending
    /// refresh until the owning backend acknowledges the public reload API.
    func writeOwnedEnablement(_ values: [String: Bool]) throws {
        guard !values.isEmpty else { return }
        guard values.keys.allSatisfy(owns(key:)) else { throw CodexHookConfigurationError.configurationChanged }
        let config = root.appendingPathComponent("config.toml")
        try rejectSymlink(config)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: config.path),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024 else { throw CodexHookConfigurationError.unsafeFile }
        let before = try Data(contentsOf: config)
        let after = try CodexHookConfigEditor.settingEnablement(values, in: before)
        guard before != after else { return }
        guard try Data(contentsOf: config) == before else { throw CodexHookConfigurationError.configurationChanged }
        let backup = root.appendingPathComponent("config.notchx-backup-\(UUID().uuidString).toml")
        try before.write(to: backup, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try after.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }

    private func helperData(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: url.path) else { throw CodexHookConfigurationError.missingHelper }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func replaceHelper(_ bundledHelper: URL) throws {
        _ = try helperData(bundledHelper)
        let directory = helper.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try rejectSymlink(helper)
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: bundledHelper, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, helper.path) == 0 else { throw CodexHookConfigurationError.unsafeFile }
    }

    func remove() throws {
        let existing = try read()
        try write(merged(existing: existing, installing: false), replacing: existing)
        // Keep the tiny helper: in-flight hooks may still be using it. It does
        // nothing without a receiving app and is replaced on explicit install.
    }

    func merged(existing: Data, installing: Bool) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
              object["hooks"] == nil || object["hooks"] is [String: Any] else { throw CodexHookConfigurationError.invalidConfiguration }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for name in Set(hooks.keys).union(AgentHookEnvelope.events).sorted() {
            if !AgentHookEnvelope.events.contains(name), !(hooks[name] is [[String: Any]]) { continue }
            guard hooks[name] == nil || hooks[name] is [[String: Any]] else { throw CodexHookConfigurationError.invalidConfiguration }
            var groups: [[String: Any]] = []
            for var group in hooks[name] as? [[String: Any]] ?? [] {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CodexHookConfigurationError.invalidConfiguration }
                let remaining = handlers.filter { handler in
                    guard let value = handler["command"] as? String else { return true }
                    return !value.hasPrefix(commandPrefix)
                }
                if !remaining.isEmpty { group["hooks"] = remaining; groups.append(group) }
            }
            if installing && AgentHookEnvelope.events.contains(name) {
                // Ordinary hooks finish after a short local acknowledgement.
                // Approval has a separate bounded response channel.
                groups.append(["hooks": [["type": "command", "command": command,
                    "timeout": Self.timeout(for: name)]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = groups }
        }
        object["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func timeout(for event: String) -> Int {
        event == "PermissionRequest" ? 125 : (event == "SessionEnd" || event == "Interrupt" ? 3 : 5)
    }

    private func rejectSymlink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw CodexHookConfigurationError.unsafeFile }
        } else if errno != ENOENT { throw CodexHookConfigurationError.unsafeFile }
    }

    private func read() throws -> Data {
        try rejectSymlink(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return Data("{}".utf8) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024 else { throw CodexHookConfigurationError.unsafeFile }
        return try Data(contentsOf: file)
    }

    private func write(_ data: Data, replacing previous: Data) throws {
        if data == previous { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymlink(file)
        guard try read() == previous else { throw CodexHookConfigurationError.configurationChanged }
        if FileManager.default.fileExists(atPath: file.path) {
            // Unique backups, no overwrites, and no private configuration in logs.
            let backup = root.appendingPathComponent("hooks.notchx-backup-\(UUID().uuidString).json")
            try previous.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
