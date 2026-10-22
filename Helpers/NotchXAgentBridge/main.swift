import Foundation
import Darwin

// This executable never starts the app, modifies Codex configuration, runs an
// agent, or emits developer context. Failure always yields a neutral hook result.
func runBridge() {
    var event = ""
    var decision = AgentHookDecision.deferToApp
    defer { FileHandle.standardOutput.write(decision.hookOutput(for: event)) }
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4, arguments[0] == "--socket", arguments[2] == "--codex-home" else { return }
    let policy = URL(fileURLWithPath: CommandLine.arguments[0]).appendingPathExtension("policy.json")
    var policyInfo = stat()
    if lstat(policy.path, &policyInfo) == 0 {
        guard policyInfo.st_mode & S_IFMT == S_IFREG, policyInfo.st_uid == getuid(),
              policyInfo.st_size > 0, policyInfo.st_size <= 4096,
              let bytes = try? Data(contentsOf: policy),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["version"] as? Int == 1, value["enabled"] as? Bool == true else { return }
    }
    do {
        var input = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            try AgentUnixSocket.wait(STDIN_FILENO, events: Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return }
            if count == 0 { break }
            guard input.count + count <= AgentHookEnvelope.maximumBytes else { return }
            input.append(contentsOf: bytes.prefix(count))
        }
        var envelope = try AgentHookEnvelope.decodeHook(input)
        event = envelope.event
        CodexHookMetadata.enrich(&envelope, input: input, root: URL(fileURLWithPath: arguments[3]))
        guard envelope.isValid else { return }
        let timeout: TimeInterval = envelope.event == "PermissionRequest" ? 120 : 0.75
        decision = try AgentUnixSocket.exchange(envelope, path: arguments[1], timeout: timeout).decision
    } catch { /* Neutral response: normal Codex behavior remains in charge. */ }
}

runBridge()
