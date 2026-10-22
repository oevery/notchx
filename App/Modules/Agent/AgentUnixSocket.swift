import Foundation
import Darwin

/// Shared bounded Unix-socket I/O. The bridge has no polling loop while idle;
/// poll() sleeps in the kernel and every operation has one monotonic deadline.
enum AgentUnixSocket {
    static var defaultPath: String { "/tmp/notchx-agent-\(getuid())/hook.sock" }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity,
              !path.utf8.contains(0) else { throw AgentHookWireError.unsafePath }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strlcpy($0, path, capacity)
            }
        }
        return address
    }

    static func prepareDirectory(for path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw AgentHookWireError.unsafePath }
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw AgentHookWireError.unsafePath }
    }

    static func ownedSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid()
            && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o077 == 0
    }

    static func descriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentHookWireError.unavailable }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            close(fd); throw AgentHookWireError.unavailable
        }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AgentHookWireError.timedOut }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&entry, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, entry.revents & (events | Int16(POLLHUP)) != 0 else { throw AgentHookWireError.unavailable }
            return
        }
    }

    static func write(_ data: Data, to fd: Int32, until deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), until: deadline)
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw AgentHookWireError.unavailable }
            offset += count
        }
    }

    static func exchange(_ envelope: AgentHookEnvelope, path: String, timeout: TimeInterval) throws -> AgentHookReply {
        guard ownedSocket(path) else { throw AgentHookWireError.unavailable }
        let fd = try descriptor()
        defer { close(fd) }
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if connected != 0 {
            guard errno == EINPROGRESS else { throw AgentHookWireError.unavailable }
            try wait(fd, events: Int16(POLLOUT), until: min(deadline, ProcessInfo.processInfo.systemUptime + 0.25))
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw AgentHookWireError.unavailable }
        }
        var peer: uid_t = 0, group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else { throw AgentHookWireError.unavailable }
        var message = try JSONEncoder().encode(envelope)
        guard message.count <= AgentHookEnvelope.maximumBytes else { throw AgentHookWireError.invalidMessage }
        message.append(10)
        try write(message, to: fd, until: min(deadline, ProcessInfo.processInfo.systemUptime + 0.5))
        var response = Data()
        while response.count <= 4096 {
            try wait(fd, events: Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw AgentHookWireError.unavailable }
            response.append(contentsOf: bytes.prefix(count))
            if let end = response.firstIndex(of: 10) {
                let reply = try JSONDecoder().decode(AgentHookReply.self, from: response.prefix(upTo: end))
                guard reply.id == envelope.id else { throw AgentHookWireError.invalidMessage }
                return reply
            }
        }
        throw AgentHookWireError.invalidMessage
    }
}
