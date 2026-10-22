import AppKit
import ApplicationServices

protocol FavoriteAccess: Sendable {
    func isAuthorized() async -> Bool
    func read() async -> Bool?
    /// Only press when the live menu still matches the state the user saw.
    func toggle(expected: Bool) async -> Bool
}

/// Native AX only: no Apple Events, UI activation, screenshots or permission prompt.
/// All AX references and cache access stay on this serial queue.
final class NetEaseFavoriteAccess: FavoriteAccess, @unchecked Sendable {
    static let bundleID = "com.netease.163music"
    private let queue = DispatchQueue(label: "app.notchx.netease-favorite", qos: .utility)
    private var cachedPID: pid_t?
    private var cachedItem: AXUIElement?

    func isAuthorized() async -> Bool { AXIsProcessTrusted() }

    static func state(for title: String) -> Bool? {
        switch title {
        case "喜欢歌曲", "喜欢": return false
        case "取消喜欢", "取消喜欢歌曲": return true
        default: return nil
        }
    }

    func read() async -> Bool? {
        await perform { ticket in
            guard !ticket.isCancelled, let item = self.item() else { return nil }
            return self.state(item)
        }
    }

    func toggle(expected: Bool) async -> Bool {
        await perform { ticket in
            guard let item = self.item(), self.state(item) == expected else { return false }
            // Serialize cancellation with the actual press, including cancellation
            // while menu discovery was in progress. Never retry a possibly sent press.
            return ticket.press(item)
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (Ticket) -> T) async -> T {
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work(ticket)) }
            }
        } onCancel: { ticket.cancel() }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func state(_ item: AXUIElement) -> Bool? {
        guard value(item, kAXEnabledAttribute) as? Bool == true,
              let title = value(item, kAXTitleAttribute) as? String else { return nil }
        return Self.state(for: title)
    }

    private func children(_ item: AXUIElement) -> [AXUIElement] {
        Array(((value(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(80))
    }

    private func item() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            cachedItem = nil
            cachedPID = nil
            return nil
        }
        if cachedPID == app.processIdentifier, let cachedItem, state(cachedItem) != nil { return cachedItem }
        cachedPID = app.processIdentifier
        cachedItem = nil
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let rawBar = value(root, kAXMenuBarAttribute), CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return nil }
        let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
        let deadline = Date().addingTimeInterval(0.6)
        // Search only the native Control menu, never the web content/window tree.
        guard let control = children(bar).first(where: { value($0, kAXTitleAttribute) as? String == "控制" }) else { return nil }
        for menu in children(control) {
            for item in children(menu) {
                guard Date() < deadline else { return nil }
                if state(item) != nil {
                    cachedItem = item
                    return item
                }
            }
        }
        return nil
    }

    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
        func press(_ item: AXUIElement) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
    }
}
