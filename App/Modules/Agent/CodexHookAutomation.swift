import Foundation
import Darwin

struct CodexManagedHook: Codable, Equatable, Sendable {
    let key: String
    let definition: String
    let event: String
}

/// Serializes finite management work with provider lifecycle. Coverage is per
/// thread; config writes remain limited to positively identified NotchX keys.
@MainActor
final class CodexHookAutomation {
    typealias Request = @Sendable (String, Data) async throws -> Data
    static let shared = CodexHookAutomation(configuration: .standard)
    private(set) var state: CodexHookManagementState = .checking
    private(set) var suspendedEvents: Set<String> = []
    private(set) var lastError = false
    private let configuration: CodexHookConfiguration
    private let bundledHelper: URL
    private let request: Request
    private var generation = UUID()
    private var signature: String?
    private var work: Task<Void, Never>?
    private var lastIntent: (active: Bool, events: Set<String>, maintain: Bool, refreshable: Bool)?
    private var lastAttempt: TimeInterval = 0
    private var installationAllowed = true
    private var receive: (@MainActor (CodexHookManagementState, Set<String>) -> Void)?

    init(configuration: CodexHookConfiguration, bundledHelper: URL? = nil, request: Request? = nil) {
        self.configuration = configuration
        self.bundledHelper = bundledHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchXAgentBridge")
        let root = configuration.root
        self.request = request ?? { method, params in
            try await CodexDaemonControl.request(root: root, method: method, params: params)
        }
    }

    /// A verified execution owner is sufficient for the primary-first policy.
    /// Unknown/uncovered active threads must not inherit another thread's coverage.
    static func needsFallback(snapshots: [CodexPrimarySnapshot], activeThreads: Set<String>) -> Bool {
        let roots = snapshots.filter { $0.classification == .userSession && $0.capabilities.contains(.lifecycle) }
        return roots.isEmpty || !activeThreads.isSubset(of: Set(roots.map(\.threadID)))
    }

    static func suspendableEvents(snapshots: [CodexPrimarySnapshot], activeThreads: Set<String>) -> Set<String> {
        needsFallback(snapshots: snapshots, activeThreads: activeThreads) ? [] : Set(AgentHookEnvelope.events)
    }

    func configure(active: Bool, fallbackEnabled: Bool = false, snapshots: [CodexPrimarySnapshot] = [], activeThreads: Set<String> = [],
                   receive: (@MainActor (CodexHookManagementState, Set<String>) -> Void)? = nil) {
        self.receive = receive
        let events = active && fallbackEnabled ? Self.suspendableEvents(snapshots: snapshots, activeThreads: activeThreads) : []
        let enabled = active && fallbackEnabled && events.isEmpty && installationAllowed
        let refreshable = !snapshots.isEmpty && snapshots.allSatisfy { $0.kind == .daemon }
        lastIntent = (enabled, events, active, refreshable)
        schedule(active: enabled, events: events, maintain: active, refreshable: refreshable, force: false)
    }

    func refresh() {
        guard let intent = lastIntent else { return }
        schedule(active: intent.active, events: intent.events, maintain: intent.maintain, refreshable: intent.refreshable, force: true)
    }

    /// An explicit Remove must not be undone by the next coverage callback.
    /// Only an explicit install/enable intent permits installation again.
    func pauseInstallation() {
        installationAllowed = false
        guard let intent = lastIntent else { return }
        lastIntent = (false, [], intent.maintain, intent.refreshable)
        schedule(active: false, events: [], maintain: intent.maintain, refreshable: intent.refreshable, force: true)
    }

    func allowInstallation() { installationAllowed = true }

    func finish() async { await work?.value }

    private func schedule(active: Bool, events: Set<String>, maintain: Bool, refreshable: Bool, force: Bool) {
        let next = "\(active)-\(maintain)-\(refreshable)-" + events.sorted().joined(separator: ",")
        guard force || signature != next || ProcessInfo.processInfo.systemUptime - lastAttempt > 30 else { return }
        lastAttempt = ProcessInfo.processInfo.systemUptime
        signature = next
        generation = UUID()
        let expected = generation, previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == expected else { return }
            await self.reconcile(active: active, events: events, maintain: maintain, refreshable: refreshable, expected: expected)
        }
    }

    private func publish(_ state: CodexHookManagementState, events: Set<String> = []) {
        self.state = state; suspendedEvents = events
        receive?(state, events)
    }

    private func call(_ method: String, _ object: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let reply = try await request(method, data)
        guard reply.count <= 4 * 1024 * 1024,
              let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw AgentHookWireError.invalidMessage }
        return result
    }

    private func reconcile(active: Bool, events: Set<String>, maintain: Bool, refreshable: Bool, expected: UUID) async {
        let configuration = configuration, helper = bundledHelper
        lastError = false
        var changedDefinition = false
        do {
            let installed = await Task.detached(priority: .utility) { configuration.hasOwnedHooks() }.value
            // Default activation does not create integration files or probe a
            // daemon merely to manage Hooks that have never been installed.
            if !active && !installed {
                try await Task.detached(priority: .utility) {
                    if FileManager.default.fileExists(atPath: configuration.helper.path)
                        || FileManager.default.fileExists(atPath: configuration.runtimePolicyFile.path) {
                        try configuration.setRuntimeEnabled(false)
                    }
                }.value
                guard generation == expected else { return }
                publish(.off)
                return
            }
            changedDefinition = try await Task.detached(priority: .utility) {
                var changed = false
                if active && !installed {
                    try configuration.install(bundledHelper: helper); changed = true
                } else if installed && maintain {
                    if !configuration.isInstalled() { try configuration.install(bundledHelper: helper); changed = true }
                    else if configuration.helperStatus(bundledHelper: helper) != .current { try configuration.updateHelper(bundledHelper: helper) }
                }
                try configuration.setRuntimeEnabled(active)
                return changed
            }.value
            guard generation == expected else { return }
            let ledger = try await Task.detached(priority: .utility) { try Self.readLedger(configuration) }.value
            let list = try await call("hooks/list", ["cwds": []])
            let entries = list["data"] as? [[String: Any]] ?? []
            let hooks = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
                configuration.owns(command: $0["command"] as? String ?? "", sourcePath: $0["sourcePath"] as? String)
            }
            guard !hooks.isEmpty else { publish(active ? .waitingForTrust : .off); return }
            var saved = Dictionary(uniqueKeysWithValues: ledger.map { ($0.key, $0) })
            var edits: [[String: Any]] = []
            var unknownTrust = false
            var nextEvents: Set<String> = []
            for hook in hooks {
                guard let key = hook["key"] as? String, configuration.owns(key: key),
                      let definition = hook["currentHash"] as? String,
                      let enabled = hook["enabled"] as? Bool,
                      hook["isManaged"] as? Bool != true else { continue }
                let event = Self.eventName(hook["eventName"] as? String ?? "")
                let trusted = hook["trustStatus"] as? String == "trusted"
                unknownTrust = unknownTrust || !trusted
                let previous = saved[key]
                if previous?.definition != definition { saved.removeValue(forKey: key) }
                let ownedDisable = previous?.definition == definition
                let desired: Bool
                if !active || (trusted && events.contains(event)) {
                    desired = false
                    if enabled { saved[key] = CodexManagedHook(key: key, definition: definition, event: event) }
                    if active && events.contains(event) { nextEvents.insert(event) }
                } else if ownedDisable { desired = true; saved.removeValue(forKey: key) }
                else { continue } // A pre-existing disabled hook is the user's choice.
                if enabled != desired {
                    let quoted = try Self.jsonString(key)
                    edits.append(["keyPath": "hooks.state." + quoted + ".enabled", "value": desired, "mergeStrategy": "replace"])
                }
            }
            guard generation == expected else { return }
            // Keep recovery records until the owning runtime acknowledges the
            // refresh, even if a prior partial write already changed disk state.
            let recovery = Array(Dictionary(ledger.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
                .merging(saved, uniquingKeysWith: { _, new in new }).values)
            try await Task.detached(priority: .utility) { try Self.saveLedger(recovery, configuration: configuration) }.value
            let config = try await call("config/read", ["includeLayers": true])
            let layers = config["layers"] as? [[String: Any]] ?? []
            let path = configuration.root.appendingPathComponent("config.toml").resolvingSymlinksInPath().path
            guard let layer = layers.first(where: {
                guard let name = $0["name"] as? [String: Any], name["type"] as? String == "user", let file = name["file"] as? String else { return false }
                return URL(fileURLWithPath: file).resolvingSymlinksInPath().path == path
            }), let version = layer["version"] as? String else { publish(.waitingForRefresh); return }
            guard generation == expected else { return }
            if !edits.isEmpty || (!ledger.isEmpty && (state == .checking || state == .waitingForRefresh)) {
                let written = try await call("config/batchWrite", ["edits": edits, "filePath": path,
                    "expectedVersion": version, "reloadUserConfig": true])
                guard written["status"] as? String == "ok" else { publish(.waitingForRefresh); return }
            }
            try await Task.detached(priority: .utility) { try Self.saveLedger(Array(saved.values), configuration: configuration) }.value
            guard generation == expected else { return }
            let state: CodexHookManagementState
            if !active && !refreshable && (!edits.isEmpty || !ledger.isEmpty) { state = .waitingForRefresh }
            else if !active { state = events.isEmpty ? .off : .suspended }
            else { state = unknownTrust ? .waitingForTrust : .ready }
            publish(state, events: !active ? events : nextEvents)
        } catch {
            guard generation == expected else { return }
            lastError = true
            // Restore only flags actually changed by NotchX, before a new
            // embedded client can load them. Existing runtimes still require
            // their owner's reload; do not claim failover was instantaneous.
            var recoveryCount = 0
            do {
                recoveryCount = try await Task.detached(priority: .utility) {
                    let records = try Self.readLedger(configuration).filter { configuration.owns(key: $0.key) }
                    let flags = Dictionary(uniqueKeysWithValues: records.map { ($0.key, active) })
                    try configuration.writeOwnedEnablement(flags)
                    return records.count
                }.value
            } catch { /* Preserve the recovery ledger; opening settings reports pending refresh. */ }
            publish(!active ? .waitingForRefresh : changedDefinition ? .waitingForTrust : recoveryCount > 0 || !events.isEmpty ? .waitingForRefresh : .unavailable)
        }
    }

    nonisolated private static func eventName(_ value: String) -> String {
        AgentHookEnvelope.events.first { $0.prefix(1).lowercased() + $0.dropFirst() == value } ?? value
    }

    nonisolated private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    nonisolated private static func ledgerFile(_ configuration: CodexHookConfiguration) -> URL { configuration.helper.appendingPathExtension("state.json") }

    nonisolated private static func readLedger(_ configuration: CodexHookConfiguration) throws -> [CodexManagedHook] {
        let file = ledgerFile(configuration)
        var info = stat()
        guard lstat(file.path, &info) == 0 else { if errno == ENOENT { return [] }; throw CodexHookConfigurationError.unsafeFile }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 256 * 1024 else { throw CodexHookConfigurationError.unsafeFile }
        let values = try JSONDecoder().decode([CodexManagedHook].self, from: Data(contentsOf: file))
        guard values.count <= 100, Set(values.map(\.key)).count == values.count else { throw CodexHookConfigurationError.invalidConfiguration }
        return values
    }

    nonisolated private static func saveLedger(_ records: [CodexManagedHook], configuration: CodexHookConfiguration) throws {
        _ = try readLedger(configuration)
        let file = ledgerFile(configuration)
        let data = try JSONEncoder().encode(records.sorted { $0.key < $1.key })
        if (try? Data(contentsOf: file)) == data { return }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
