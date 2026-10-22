import Foundation
import Darwin

/// One event-driven listener and bounded client set. Pending approvals keep a
/// socket, not a worker thread or a busy loop. All descriptors belong to io.
final class AgentHookServer: @unchecked Sendable {
    private final class Client {
        let fd: Int32
        var bytes = Data()
        var reader: DispatchSourceRead?
        var deadline: DispatchWorkItem?
        var envelopeID: String?
        init(fd: Int32) { self.fd = fd }
    }
    let path: String
    private let io = DispatchQueue(label: "app.notchx.agent-socket", qos: .utility)
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var clients: [UUID: Client] = [:]
    private var receive: (@Sendable (AgentHookEnvelope) -> Void)?
    private var closed: (@Sendable (String) -> Void)?

    init(path: String = AgentUnixSocket.defaultPath) { self.path = path }

    func start(receive: @escaping @Sendable (AgentHookEnvelope) -> Void,
               closed: @escaping @Sendable (String) -> Void) throws {
        try io.sync {
            guard listener == nil else { return }
            try AgentUnixSocket.prepareDirectory(for: path)
            let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw AgentHookWireError.unsafePath }
            var lockInfo = stat()
            guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(),
                  lockInfo.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock); throw AgentHookWireError.busy
            }
            var fd: Int32 = -1
            var didBind = false
            do {
                fd = try AgentUnixSocket.descriptor()
                // Only the lock owner may reclaim a stale, same-user socket.
                var info = stat()
                if lstat(path, &info) == 0 {
                    guard AgentUnixSocket.ownedSocket(path) else { throw AgentHookWireError.unsafePath }
                    unlink(path)
                }
                var address = try AgentUnixSocket.address(path)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else { throw AgentHookWireError.unavailable }
                didBind = true
                guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                    throw AgentHookWireError.unavailable
                }
            } catch {
                if fd >= 0 { Darwin.close(fd) }
                if didBind { unlink(path) }
                Darwin.close(lock)
                throw error
            }
            lockFD = lock
            self.receive = receive
            self.closed = closed
            let listenerFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: io)
            source.setEventHandler { [weak self] in self?.acceptClients(listenerFD) }
            source.setCancelHandler { Darwin.close(listenerFD) }
            listener = source
            source.resume()
        }
    }

    func respond(id: String, decision: AgentHookDecision) {
        io.async { [weak self] in
            guard let self, let key = self.clients.first(where: { $0.value.envelopeID == id })?.key else { return }
            self.finish(key, decision: decision)
        }
    }

    func stop() {
        io.sync {
            for key in Array(clients.keys) { finish(key, decision: .deferToApp) }
            listener?.cancel()
            listener = nil
            if lockFD >= 0 {
                unlink(path)
                Darwin.close(lockFD)
                lockFD = -1
            }
            receive = nil
            closed = nil
        }
    }

    deinit {
        // Owners call stop synchronously on disable. This also closes an
        // unexpectedly released listener without retaining a shared singleton.
        listener?.cancel()
        for client in clients.values { client.deadline?.cancel(); client.reader?.cancel() }
        if lockFD >= 0 { unlink(path); Darwin.close(lockFD) }
    }

    private func acceptClients(_ fd: Int32) {
        guard listener != nil else { return }
        // Bound work per callback as well as concurrent connections.
        for _ in 0..<16 {
            let accepted = accept(fd, nil, nil)
            guard accepted >= 0 else { return }
            var user: uid_t = 0, group: gid_t = 0
            guard clients.count < 16, getpeereid(accepted, &user, &group) == 0, user == getuid(),
                  fcntl(accepted, F_SETFL, O_NONBLOCK) == 0, fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0 else {
                Darwin.close(accepted); continue
            }
            var enabled: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let key = UUID(), client = Client(fd: accepted)
            clients[key] = client
            let reader = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: io)
            reader.setEventHandler { [weak self] in self?.readClient(key) }
            reader.setCancelHandler { Darwin.close(accepted) }
            client.reader = reader
            reader.resume()
            expire(key, after: 2)
        }
    }

    private func readClient(_ key: UUID) {
        guard let client = clients[key] else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<17 {
            let count = Darwin.read(client.fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { finish(key, decision: .deferToApp); return }
            guard client.envelopeID == nil, client.bytes.count + count <= AgentHookEnvelope.maximumBytes + 1 else {
                finish(key, decision: .deferToApp); return
            }
            client.bytes.append(contentsOf: bytes.prefix(count))
            if let end = client.bytes.firstIndex(of: 10) {
                guard end == client.bytes.index(before: client.bytes.endIndex),
                      let message = try? JSONDecoder().decode(AgentHookEnvelope.self, from: client.bytes.prefix(upTo: end)),
                      message.isValid else { finish(key, decision: .deferToApp); return }
                client.bytes.removeAll(keepingCapacity: false)
                client.envelopeID = message.id
                expire(key, after: message.event == "PermissionRequest" ? 110 : 1)
                receive?(message)
                return
            }
        }
    }

    private func expire(_ key: UUID, after seconds: TimeInterval) {
        clients[key]?.deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(key, decision: .deferToApp) }
        clients[key]?.deadline = work
        io.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ key: UUID, decision: AgentHookDecision) {
        guard let client = clients.removeValue(forKey: key) else { return }
        client.deadline?.cancel()
        if let id = client.envelopeID, var bytes = try? JSONEncoder().encode(AgentHookReply(id: id, decision: decision)) {
            bytes.append(10)
            // Replies are tiny. No wait on the serial listener: a backpressured
            // peer gets a disconnect and the bridge's neutral fallback.
            bytes.withUnsafeBytes { _ = Darwin.write(client.fd, $0.baseAddress, bytes.count) }
            closed?(id)
        }
        client.reader?.cancel()
    }
}
