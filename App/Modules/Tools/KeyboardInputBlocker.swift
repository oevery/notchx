import AppKit
import CoreGraphics
import Carbon.HIToolbox

@MainActor
protocol KeyboardInputBlocking: AnyObject {
    var hasAccessibility: Bool { get }
    var hasPressedKeys: Bool { get }
    var isHealthy: Bool { get }
    func start(onInterruption: @escaping () -> Void) -> Bool
    func stop()
}

/// Its tap and every callback run on the main run loop. Mouse events are never filtered.
final class KeyboardInputBlocker: KeyboardInputBlocking {
    /// Also checked by NotchX's older taps, whose ordering can change after permission return.
    nonisolated(unsafe) static private(set) var isBlockingKeyboardEvents = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onInterruption: (() -> Void)?

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasPressedKeys: Bool {
        (0..<128).contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
    }
    var isHealthy: Bool {
        guard let eventTap else { return false }
        return hasAccessibility && !IsSecureEventInputEnabled()
            && CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start(onInterruption: @escaping () -> Void) -> Bool {
        guard eventTap == nil, hasAccessibility, !hasPressedKeys, !IsSecureEventInputEnabled() else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let blocker = Unmanaged<KeyboardInputBlocker>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { blocker.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.onInterruption = onInterruption
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isHealthy else { stop(); return false }
        Self.isBlockingKeyboardEvents = true
        return true
    }

    func stop() {
        Self.isBlockingKeyboardEvents = false
        onInterruption = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never silently re-enable after input may already have escaped.
            let interrupted = onInterruption
            stop()
            DispatchQueue.main.async { interrupted?() }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
}
