import Foundation
import Darwin

/// Compatibility reader for new public records only. Never extracts reasoning,
/// final replies, old prompts or tool output, and never enumerates chats.
struct CodexTranscriptParser {
    let turnID: String
    private var inTurn = true
    private var canRecoverByID = false
    private var pending: AgentPendingInput?

    init(turnID: String) { self.turnID = turnID }
    mutating func invalidateScope() { inTurn = false; canRecoverByID = true; pending = nil }

    mutating func consume(_ data: Data) -> CodexTranscriptSignal? {
        guard data.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        if object["type"] as? String == "turn_context" {
            inTurn = payload["turn_id"] as? String == turnID
            canRecoverByID = false
            return nil
        }
        if object["type"] as? String == "event_msg", payload["type"] as? String == "task_started" {
            inTurn = payload["turn_id"] as? String == turnID; canRecoverByID = false; return nil
        }
        let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        let recordTurn = payload["turn_id"] as? String ?? metadata?["turn_id"] as? String
        if let turn = recordTurn, turn != turnID { return nil }
        guard inTurn || canRecoverByID && recordTurn == turnID else { return nil }
        if object["type"] as? String == "event_msg" {
            switch payload["type"] as? String {
            case "task_complete": inTurn = false; canRecoverByID = false; return .ended
            case "turn_aborted": inTurn = false; canRecoverByID = false; return .cancelled
            case "user_message": pending = nil; return .answered
            default: return nil
            }
        }
        guard object["type"] as? String == "response_item" else { return nil }
        if payload["type"] as? String == "message", payload["role"] as? String == "user" { pending = nil; return .answered }
        if payload["type"] as? String == "message", payload["role"] as? String == "assistant",
           (payload["phase"] as? String ?? payload["channel"] as? String) == "commentary",
           let content = payload["content"] as? [[String: Any]],
           let text = AgentMessagePreview.line(content.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined(separator: " ")) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let raw = object["timestamp"] as? String
            var date = raw.flatMap(formatter.date(from:))
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = raw.flatMap(formatter.date(from:))
            }
            return .progress(text, at: date)
        }
        if payload["type"] as? String == "function_call",
           let name = (payload["name"] as? String)?.split(separator: ".").last,
           ["request_user_input", "request_user_input_async"].contains(String(name)),
           let id = payload["call_id"] as? String, AgentHookEnvelope.validID(id),
           let arguments = payload["arguments"] as? String, let bytes = arguments.data(using: .utf8),
           let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let questions = input["questions"] as? [[String: Any]], let first = questions.first,
           let text = AgentMessagePreview.line(first["question"] as? String ?? first["title"] as? String) {
            let question = AgentPendingInput(id: id, text: text, asynchronous: name == "request_user_input_async")
            pending = question; return .question(question)
        }
        if payload["type"] as? String == "function_call_output", let question = pending,
           payload["call_id"] as? String == question.id, !question.asynchronous {
            pending = nil; return .answered
        }
        return nil
    }
}

/// At most one descriptor per verified live root, owned by the source. Reads
/// begin at EOF; write notifications replace polling and never restore history.
final class CodexTranscriptObserver: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private var offset: off_t
    private var parser: CodexTranscriptParser
    private var pending = Data()
    private var discardingLine = false
    private let receive: @Sendable ([CodexTranscriptSignal]) -> Void

    init(file: URL, root: URL, sessionID: String, turnID: String,
         receive: @escaping @Sendable ([CodexTranscriptSignal]) -> Void) throws {
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.appendingPathComponent("sessions").path + "/") else { throw AgentHookWireError.unsafePath }
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentHookWireError.unavailable }
        var owned = false
        defer { if !owned { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw AgentHookWireError.unsafePath }
        var header = [UInt8](repeating: 0, count: 256 * 1024)
        let count = pread(descriptor, &header, header.count, 0)
        guard count > 0, let end = header.prefix(count).firstIndex(of: 10),
              let record = try? JSONSerialization.jsonObject(with: Data(header[..<end])) as? [String: Any],
              record["type"] as? String == "session_meta", let metadata = record["payload"] as? [String: Any],
              metadata["id"] as? String == sessionID, metadata["thread_source"] as? String == "user",
              metadata["parent_thread_id"] == nil else { throw AgentHookWireError.invalidMessage }
        if let source = metadata["source"] as? [String: Any], source["subagent"] != nil || source["internal"] != nil { throw AgentHookWireError.invalidMessage }
        fd = descriptor; offset = info.st_size; parser = CodexTranscriptParser(turnID: turnID); self.receive = receive
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename],
            queue: DispatchQueue(label: "app.notchx.agent.live-records", qos: .utility))
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(descriptor) }
        owned = true; source.resume()
    }

    func stop() { source.cancel() }
    var isActive: Bool { !source.isCancelled }
    deinit { source.cancel() }

    private func changed() {
        guard !source.isCancelled else { return }
        if !source.data.intersection([.delete, .rename]).isEmpty { source.cancel(); return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= offset else { source.cancel(); return }
        let budget: off_t = 256 * 1024
        if info.st_size - offset > budget {
            offset = info.st_size - budget; pending.removeAll(keepingCapacity: true); discardingLine = true
            parser.invalidateScope()
        }
        let length = Int(min(budget, info.st_size - offset))
        guard length > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: length)
        let count = pread(fd, &bytes, length, offset)
        guard count > 0 else { return }
        offset += off_t(count); pending.append(contentsOf: bytes.prefix(count))
        var signals: [CodexTranscriptSignal] = []
        var cursor = pending.startIndex
        while let end = pending[cursor...].firstIndex(of: 10) {
            let line = Data(pending[cursor..<end]); cursor = pending.index(after: end)
            if discardingLine { discardingLine = false; continue }
            if line.count > 256 * 1024 { parser.invalidateScope(); continue }
            if let signal = parser.consume(line) { signals.append(signal) }
        }
        pending.removeSubrange(..<cursor)
        if pending.count > 256 * 1024 { pending.removeAll(keepingCapacity: true); discardingLine = true; parser.invalidateScope() }
        if !signals.isEmpty, !source.isCancelled { receive(Array(signals.suffix(64))) }
    }
}
