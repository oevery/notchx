import Darwin
import Foundation

/// Prevents overlapping submissions with the same ID in this process.
/// Ownership metadata identifies reservations; it does not authorize cleanup.
final class CodexDesktopQueueLeases: @unchecked Sendable {
    static let shared = CodexDesktopQueueLeases()
    private let lock = NSLock()
    private let instanceID = UUID().uuidString
    private var active: Set<String> = []

    func marker(id: String) -> [String: Any] {
        ["owner": "notchx", "version": 1, "messageId": id,
         "processId": Int(getpid()), "instanceId": instanceID]
    }

    func begin(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.insert(id).inserted
    }

    func end(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        active.remove(id)
    }
}
