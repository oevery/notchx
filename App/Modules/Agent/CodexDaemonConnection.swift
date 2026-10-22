import CryptoKit
import Darwin
import Foundation

/// WebSocket JSON-RPC over an existing same-user Unix socket. No CLI process,
/// daemon bootstrap, resume, or transport downgrade is performed here.
final class CodexDaemonConnection: @unchecked Sendable {
    struct Failure: Error {
        let submitted: Bool
        let code: Int?
        var unmaterializedThread: String? = nil
    }
    private let path: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "app.notchx.codex-daemon", qos: .utility)
    private let lock = NSLock()
    private var descriptor: Int32?
    private var cancelled = false
    private var buffer = Data()
    private var ready = false
    private var nextID = 0
    private var deadline: TimeInterval = 0
    private let maximumBytes = 2 * 1024 * 1024
    private var reader: DispatchSourceRead?
    private let events: (@MainActor @Sendable (Data) -> Void)?
    private let disconnected: (@MainActor @Sendable () -> Void)?
    private var pendingEvents = 0
    private var pendingEventBytes = 0
    private var commentaryIDs: Set<String> = []

    init(path: String, timeout: TimeInterval = 4,
         events: (@MainActor @Sendable (Data) -> Void)? = nil,
         disconnected: (@MainActor @Sendable () -> Void)? = nil) {
        self.path = path
        self.timeout = max(0.05, min(timeout, 15))
        self.events = events
        self.disconnected = disconnected
    }

    /// Allows the daemon's owned rendezvous symlink, but never follows an
    /// arbitrary chain or trusts a world-writable target directory/socket.
    static func ownedSocket(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        func safeDirectory(_ directory: String, privateOnly: Bool) -> Bool {
            var info = stat()
            return lstat(directory, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                && info.st_uid == getuid()
                && info.st_mode & (privateOnly ? 0o077 : 0o022) == 0
        }
        guard safeDirectory(parent.path, privateOnly: false) else { return nil }
        let advertised = parent.appendingPathComponent(url.lastPathComponent).path
        var info = stat()
        guard lstat(advertised, &info) == 0, info.st_uid == getuid() else { return nil }
        var physical = advertised
        if info.st_mode & S_IFMT == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(advertised, &bytes, Int(PATH_MAX))
            guard count > 0, count < Int(PATH_MAX),
                  let target = String(bytes: bytes.prefix(count), encoding: .utf8), target.hasPrefix("/") else { return nil }
            let targetURL = URL(fileURLWithPath: target).standardizedFileURL
            guard safeDirectory(targetURL.deletingLastPathComponent().path, privateOnly: true),
                  lstat(targetURL.path, &info) == 0 else { return nil }
            physical = targetURL.path
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { return nil }
        return physical
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        // The I/O queue closes the fd; shutdown wakes poll without an fd-reuse race.
        if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
    }

    func request(method: String, params: [String: Any], mutation: Bool = false) async throws -> [String: Any] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    var submitted = false
                    do {
                        deadline = ProcessInfo.processInfo.systemUptime + timeout
                        try ensureConnected()
                        nextID += 1
                        let id = nextID
                        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
                        guard payload.count <= maximumBytes else { throw Failure(submitted: false, code: nil) }
                        // Once any request bytes may have been sent, cancellation/EOF
                        // cannot establish that a mutating request was not executed.
                        submitted = mutation
                        try sendFrame(payload, opcode: 1)
                        let response = try matchingResponse(id)
                        if let error = response["error"] as? [String: Any] {
                            // Fresh resident threads have no durable turn page
                            // until their first input. Keep the healthy link.
                            if method == "thread/turns/list", let thread = params["threadId"] as? String,
                               UUID(uuidString: thread) != nil, error["code"] as? Int == -32600,
                               error["message"] as? String == "thread \(thread) is not materialized yet; thread/turns/list is unavailable before first user message" {
                                continuation.resume(throwing: Failure(submitted: false, code: -32600, unmaterializedThread: thread))
                                queue.async { [weak self] in self?.drainAvailable() }
                                return
                            }
                            // Optional protocol probes and explicit RPC rejections
                            // do not make a healthy subscribed socket unusable.
                            let code = error["code"] as? Int
                            let rejected = code.map { [-32600, -32601, -32602].contains($0) } ?? false
                            continuation.resume(throwing: Failure(submitted: mutation && !rejected, code: code))
                            queue.async { [weak self] in self?.drainAvailable() }
                            return
                        }
                        guard let result = response["result"] as? [String: Any] else {
                            throw Failure(submitted: submitted, code: nil)
                        }
                        continuation.resume(returning: result)
                        // A response can share the final read with notifications;
                        // the kernel might no longer signal those buffered bytes.
                        queue.async { [weak self] in self?.drainAvailable() }
                    } catch {
                        let failure = error as? Failure
                        closeOnQueue()
                        // An internal/server error may occur after side effects.
                        // Only explicit request rejection establishes non-delivery.
                        let rejected = failure?.code.map { [-32600, -32601, -32602].contains($0) } ?? false
                        continuation.resume(throwing: Failure(submitted: submitted && !rejected, code: failure?.code))
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    /// Reply on this exact live connection; never reconnect or replay a native
    /// server request. A successful write is not an acknowledgement.
    func respond(id: CodexNativeRequestID, result: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                var submitted = false
                do {
                    guard ready, descriptor != nil else { throw Failure(submitted: false, code: nil) }
                    lock.lock(); let stopped = cancelled; lock.unlock()
                    guard !stopped else { throw Failure(submitted: false, code: nil) }
                    let data = try JSONSerialization.data(withJSONObject: ["id": id.wireValue, "result": result])
                    guard data.count <= 64 * 1024 else { throw Failure(submitted: false, code: nil) }
                    deadline = ProcessInfo.processInfo.systemUptime + timeout
                    submitted = true
                    try sendFrame(data, opcode: 1)
                    continuation.resume()
                } catch {
                    if submitted { closeOnQueue() }
                    continuation.resume(throwing: Failure(submitted: submitted, code: nil))
                }
            }
        }
    }

    private func ensureConnected() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw Failure(submitted: false, code: nil) }
        if ready { return }
        guard let physical = Self.ownedSocket(path) else { throw Failure(submitted: false, code: nil) }
        let fd = try AgentUnixSocket.descriptor()
        lock.lock()
        if cancelled { lock.unlock(); close(fd); throw Failure(submitted: false, code: nil) }
        descriptor = fd; lock.unlock()
        var address = try AgentUnixSocket.address(physical)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Failure(submitted: false, code: nil) }
            try AgentUnixSocket.wait(fd, events: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Failure(submitted: false, code: nil) }
        }
        var peer: uid_t = 0, group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else { throw Failure(submitted: false, code: nil) }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "
            + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try AgentUnixSocket.write(Data(request.utf8), to: fd, until: deadline)
        let separator = Data([13, 10, 13, 10])
        while buffer.range(of: separator) == nil {
            guard buffer.count < 16_384 else { throw Failure(submitted: false, code: nil) }
            try fill()
        }
        guard let boundary = buffer.range(of: separator), boundary.upperBound <= 16_384,
              let headers = String(data: buffer.prefix(upTo: boundary.lowerBound), encoding: .utf8) else { throw Failure(submitted: false, code: nil) }
        buffer.removeSubrange(..<boundary.upperBound)
        let lines = headers.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "101" else { throw Failure(submitted: false, code: nil) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure(submitted: false, code: nil) }
            let name = line[..<colon].lowercased()
            guard fields[name] == nil else { throw Failure(submitted: false, code: nil) }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard fields["sec-websocket-accept"] == accept, fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              fields["sec-websocket-extensions"] == nil else { throw Failure(submitted: false, code: nil) }
        nextID += 1
        let id = nextID
        try sendFrame(JSONSerialization.data(withJSONObject: ["id": id, "method": "initialize", "params": [
            "clientInfo": ["name": "notchx", "version": "0.1"], "capabilities": ["experimentalApi": true]]]), opcode: 1)
        let response = try matchingResponse(id)
        guard response["error"] == nil, response["result"] is [String: Any] else { throw Failure(submitted: false, code: nil) }
        try sendFrame(JSONSerialization.data(withJSONObject: ["method": "initialized"]), opcode: 1)
        ready = true
        if events != nil || disconnected != nil {
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.drainAvailable() }
            self.reader = reader
            reader.resume()
        }
    }

    private func closeOnQueue() {
        let wasReady = ready
        reader?.cancel(); reader = nil
        lock.lock(); let fd = descriptor; descriptor = nil; lock.unlock()
        if let fd { close(fd) }
        ready = false; buffer.removeAll(keepingCapacity: false)
        commentaryIDs.removeAll()
        if wasReady, let disconnected { DispatchQueue.main.async { disconnected() } }
    }

    private func deliver(_ object: [String: Any]) throws {
        guard let method = object["method"] as? String, let events else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String ?? ""
        let turn = params["turnId"] as? String ?? ""
        let item = params["item"] as? [String: Any] ?? [:]
        let itemID = params["itemId"] as? String ?? item["id"] as? String ?? ""
        guard method.utf8.count <= 256, thread.utf8.count <= 256,
              turn.utf8.count <= 256, itemID.utf8.count <= 256 else { throw Failure(submitted: false, code: nil) }
        let key = thread + "/" + turn + "/" + itemID
        if ["item/started", "item/completed"].contains(method), item["type"] as? String == "agentMessage" {
            if item["phase"] as? String == "commentary" {
                guard commentaryIDs.count < 512 || commentaryIDs.contains(key) else { throw Failure(submitted: false, code: nil) }
                commentaryIDs.insert(key)
            } else { commentaryIDs.remove(key) }
        }
        if method == "turn/completed" || method == "thread/closed" {
            commentaryIDs = commentaryIDs.filter { !$0.hasPrefix(thread + "/") }
        }
        guard let data = try CodexDaemonEventWire.sanitize(object, commentaryDelta: commentaryIDs.contains(key)) else { return }
        guard pendingEvents < 256, pendingEventBytes + data.count <= maximumBytes else { throw Failure(submitted: false, code: nil) }
        pendingEvents += 1; pendingEventBytes += data.count
        // Main queue dispatch preserves wire event order. Consumers retain only
        // sanitized public state; this transport never stores a transcript.
        DispatchQueue.main.async { [weak self] in
            events(data)
            self?.queue.async { [weak self] in
                self?.pendingEvents -= 1; self?.pendingEventBytes -= data.count
            }
        }
    }

    private func drainAvailable() {
        guard ready, reader != nil, let fd = descriptor else { return }
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            for _ in 0..<256 {
                var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let available = poll(&entry, 1, 0)
                if buffer.isEmpty && available == 0 { return }
                if available < 0 && errno == EINTR { continue }
                guard available >= 0 else { throw Failure(submitted: false, code: nil) }
                try deliver(message())
            }
            queue.async { [weak self] in self?.drainAvailable() }
        } catch { closeOnQueue() }
    }

    /// Orders bootstrap completion after notifications already dispatched by
    /// the serialized reader, without retaining their raw payloads in a queue.
    func eventBarrier() async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func fill() throws {
        guard let fd = descriptor else { throw Failure(submitted: false, code: nil) }
        try AgentUnixSocket.wait(fd, events: Int16(POLLIN), until: deadline)
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0, buffer.count + count <= maximumBytes + 16_384 else { throw Failure(submitted: false, code: nil) }
        buffer.append(contentsOf: bytes.prefix(count))
    }

    private func read(_ count: Int) throws -> Data {
        guard count <= maximumBytes else { throw Failure(submitted: false, code: nil) }
        while buffer.count < count { try fill() }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count); return data
    }

    private func sendFrame(_ payload: Data, opcode: UInt8) throws {
        guard let fd = descriptor, payload.count <= maximumBytes else { throw Failure(submitted: false, code: nil) }
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            data.append(0xfe); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255))
        } else {
            data.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try AgentUnixSocket.write(data, to: fd, until: deadline)
    }

    private func message() throws -> [String: Any] {
        var message = Data(), fragmented = false
        for _ in 0..<256 {
            let header = [UInt8](try read(2)), final = header[0] & 0x80 != 0, opcode = header[0] & 15
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure(submitted: false, code: nil) }
            var length = UInt64(header[1] & 127)
            if length == 126 { length = try read(2).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            guard length <= UInt64(maximumBytes), opcode < 8 || (final && length <= 125) else { throw Failure(submitted: false, code: nil) }
            let payload = try read(Int(length))
            if opcode == 8 { throw Failure(submitted: false, code: nil) }
            if opcode == 9 { try sendFrame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented), message.count + payload.count <= maximumBytes else { throw Failure(submitted: false, code: nil) }
            message.append(payload)
            if final {
                guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { throw Failure(submitted: false, code: nil) }
                return object
            }
            fragmented = true
        }
        throw Failure(submitted: false, code: nil)
    }

    private func matchingResponse(_ id: Int) throws -> [String: Any] {
        for _ in 0..<256 {
            let object = try message()
            if object["method"] == nil, object["id"] as? Int == id { return object }
            try deliver(object)
        }
        throw Failure(submitted: false, code: nil)
    }

    deinit { reader?.cancel(); if let descriptor { close(descriptor) } }
}

/// Explicit short control transactions remain usable after a monitoring channel
/// stops. Result bytes contain only the JSON-RPC result, not its wire envelope.
enum CodexDaemonControl {
    static func request(root: URL, method: String, params: Data) async throws -> Data {
        guard ["hooks/list", "config/read", "config/batchWrite"].contains(method),
              let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw CodexDaemonConnection.Failure(submitted: false, code: -32600)
        }
        let connection = CodexDaemonConnection(path: root.appendingPathComponent("app-server-control/app-server-control.sock").path)
        defer { connection.cancel() }
        let result = try await connection.request(method: method, params: object, mutation: method == "config/batchWrite")
        return try JSONSerialization.data(withJSONObject: result)
    }
}
