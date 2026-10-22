import Foundation

/// Optional compatibility metadata, read only from this hook's exact transcript.
/// Read at most 256 KiB of the header and 256 KiB of the tail; never enumerate
/// transcripts or retain their contents. Unknown reviewer means defer to Codex.
enum CodexHookMetadata {
    static func enrich(_ envelope: inout AgentHookEnvelope, input: Data, root: URL) {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        guard let path = object["transcript_path"] as? String else {
            if envelope.agentID != nil { envelope.threadSource = "unverified" }
            return
        }
        // An unreadable/mismatched child transcript must not fall back to the
        // root's catalogue identity and accidentally finish its parent turn.
        envelope.threadSource = "unverified"
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard ["sessions", "archived_sessions"].contains(where: {
            file.path.hasPrefix(canonicalRoot.appendingPathComponent($0).path + "/")
        }), let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var header = Data()
        while !header.contains(10), header.count < 256 * 1024 {
            guard let part = try? handle.read(upToCount: 16 * 1024), !part.isEmpty else { break }
            header.append(part)
        }
        guard header.contains(10),
              let firstLine = header.split(separator: 10).first,
              let record = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              record["type"] as? String == "session_meta",
              let metadata = record["payload"] as? [String: Any],
              let threadID = metadata["id"] as? String, AgentHookEnvelope.validID(threadID) else { return }
        // Subagent hooks can carry the root's session_id. Their actual thread
        // identity is the transcript id, never the root id.
        guard threadID == envelope.sessionID || threadID == envelope.agentID else { return }
        if threadID != envelope.sessionID { envelope.parentThreadID = envelope.sessionID }
        envelope.sessionID = threadID
        if let cwd = metadata["cwd"] as? String { envelope.cwd = String(cwd.prefix(4000)) }
        if let git = metadata["git"] as? [String: Any], let branch = git["branch"] as? String { envelope.branch = String(branch.prefix(4000)) }
        envelope.threadSource = metadata["thread_source"] as? String
        if let parent = metadata["parent_thread_id"] as? String, AgentHookEnvelope.validID(parent), parent != threadID {
            envelope.threadSource = "subagent"
            envelope.parentThreadID = parent
        }
        if let source = metadata["source"] as? [String: Any] {
            if let subagent = source["subagent"] as? [String: Any],
               let spawn = subagent["spawn"] as? [String: Any],
               let parent = spawn["parent_thread_id"] as? String, AgentHookEnvelope.validID(parent) {
                envelope.threadSource = "subagent"
                envelope.parentThreadID = parent
            } else if source["internal"] != nil { envelope.threadSource = "internal" }
        }
        if envelope.threadSource == "user", envelope.parentThreadID == nil { envelope.transcriptPath = file.path }
        guard let turnID = envelope.turnID,
              let length = try? handle.seekToEnd() else { return }
        let start = length > 256 * 1024 ? length - 256 * 1024 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.read(upToCount: 256 * 1024) else { return }
        for line in tail.split(separator: 10).reversed() {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  item["type"] as? String == "turn_context",
                  let context = item["payload"] as? [String: Any],
                  context["turn_id"] as? String == turnID else { continue }
            envelope.reviewer = context["approvals_reviewer"] as? String
            if let model = context["model"] as? String { envelope.model = String(model.prefix(4000)) }
            return
        }
    }
}
