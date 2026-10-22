import Darwin
import Foundation

/// Path-only compatibility data. Never retains a patch, output or transcript.
enum CodexFileApprovalPaths {
    static func changes(_ changes: [[String: Any]]) -> [String]? {
        guard !changes.isEmpty, changes.count <= 32 else { return nil }
        var paths: [String] = []
        for change in changes {
            guard let path = path(change["path"]), path.hasPrefix("/"), let kind = change["kind"] as? [String: Any],
                  let type = kind["type"] as? String, ["add", "delete", "update"].contains(type) else { return nil }
            paths.append(path)
            if let move = kind["move_path"], !(move is NSNull) {
                guard type == "update", let destination = self.path(move), destination.hasPrefix("/") else { return nil }
                paths.append(destination)
            }
        }
        return bounded(paths)
    }

    static func patch(_ input: String, cwd: String) -> [String]? {
        guard input.utf8.count <= 256 * 1024, cwd.hasPrefix("/") else { return nil }
        var lines = input.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch", lines.count >= 3 else { return nil }
        var paths: [String] = [], section: String?, canMove = false
        for line in lines.dropFirst().dropLast() {
            let headers = [("*** Add File: ", "add"), ("*** Delete File: ", "delete"), ("*** Update File: ", "update")]
            if let (prefix, type) = headers.first(where: { line.hasPrefix($0.0) }) {
                guard let value = path(String(line.dropFirst(prefix.count))) else { return nil }
                paths.append(absolute(value, cwd: cwd)); section = type; canMove = type == "update"
            } else if line.hasPrefix("*** Move to: ") {
                guard section == "update", canMove, let value = path(String(line.dropFirst(13))) else { return nil }
                paths.append(absolute(value, cwd: cwd)); canMove = false
            } else {
                guard let section else { return nil }
                canMove = false
                if section == "add" { guard line.hasPrefix("+") else { return nil } }
                else if section == "update" {
                    guard line.hasPrefix(" ") || line.hasPrefix("+") || line.hasPrefix("-")
                        || line == "@@" || line.hasPrefix("@@ ") || line == "*** End of File" else { return nil }
                } else { return nil }
            }
        }
        return bounded(paths)
    }

    /// Reads only the exact file returned by the live daemon for this UUID.
    /// A bounded tail must contain an explicit matching turn/call identity;
    /// missing, truncated, duplicate or completed calls remain non-actionable.
    static func pending(file: URL, root: URL, thread: String, turn: String, item: String) -> [String]? {
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        let sessions = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("sessions").path + "/"
        guard file.path.hasPrefix(sessions) else { return nil }
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        let budget = 256 * 1024
        var header = [UInt8](repeating: 0, count: budget)
        let read = pread(fd, &header, budget, 0)
        guard read > 0, let end = header.prefix(read).firstIndex(of: 10),
              let record = try? JSONSerialization.jsonObject(with: Data(header[..<end])) as? [String: Any],
              record["type"] as? String == "session_meta", let metadata = record["payload"] as? [String: Any],
              metadata["id"] as? String == thread else { return nil }
        let start = max(0, info.st_size - off_t(budget))
        var bytes = [UInt8](repeating: 0, count: budget)
        let size = pread(fd, &bytes, budget, start)
        guard size > 0 else { return nil }
        return records(Data(bytes.prefix(size)), discardingFirst: start > 0, turn: turn, item: item)
    }

    static func records(_ data: Data, discardingFirst: Bool, turn: String, item: String) -> [String]? {
        guard data.count <= 256 * 1024 else { return nil }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if discardingFirst, !lines.isEmpty { lines.removeFirst() }
        // The final line may still be in flight. Only complete JSONL records count.
        if !lines.isEmpty { lines.removeLast() }
        var scope: String?, turnCwd: String?, found: [String]?, matches = 0, resolved = false
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else { scope = nil; continue }
            let type = record["type"] as? String, kind = payload["type"] as? String
            if type == "turn_context" || type == "event_msg" && kind == "task_started" {
                scope = payload["turn_id"] as? String
                if scope != turn { turnCwd = nil; if found != nil { resolved = true } }
                if type == "turn_context", scope == turn {
                    turnCwd = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
                }
            }
            let direct = (payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String ?? payload["turn_id"] as? String
            guard (direct ?? scope) == turn else { continue }
            if type == "event_msg", ["task_complete", "turn_aborted"].contains(kind ?? "") { resolved = true }
            guard type == "response_item", payload["call_id"] as? String == item else { continue }
            if kind == "function_call_output" || kind == "custom_tool_call_output" { resolved = true }
            if kind == "custom_tool_call" {
                matches += 1
                if payload["name"] as? String == "apply_patch", let input = payload["input"] as? String, let turnCwd {
                    found = patch(input, cwd: turnCwd)
                }
            }
        }
        return matches == 1 && !resolved ? found : nil
    }

    private static func path(_ value: Any?) -> String? {
        guard let value = CodexNativeRequests.text(value, limit: 4_000),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        URL(fileURLWithPath: path.hasPrefix("/") ? path : cwd + "/" + path).standardizedFileURL.path
    }

    private static func bounded(_ paths: [String]) -> [String]? {
        guard !paths.isEmpty, paths.count <= 32, paths.allSatisfy({ path($0) != nil }),
              paths.joined(separator: "\n").utf8.count <= 16_000 else { return nil }
        return paths
    }
}
