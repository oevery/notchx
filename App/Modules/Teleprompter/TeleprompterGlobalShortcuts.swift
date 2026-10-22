import AppKit
import Carbon

enum TeleprompterShortcutModifiers: String, CaseIterable, Identifiable {
    case controlOption, controlCommand, optionCommand
    var id: String { rawValue }
    var label: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        }
    }
    var carbonMask: UInt32 {
        switch self {
        case .controlOption: return UInt32(controlKey | optionKey)
        case .controlCommand: return UInt32(controlKey | cmdKey)
        case .optionCommand: return UInt32(optionKey | cmdKey)
        }
    }
}

struct TeleprompterShortcutPressState {
    private var held: Set<UInt32> = []
    mutating func shouldFire(id: UInt32, pressed: Bool) -> Bool {
        if !pressed { held.remove(id); return false }
        return held.insert(id).inserted
    }
}

/// Registered combinations use the public hot-key API, without an event tap
/// or Accessibility/Input Monitoring requests. Disabled modules unregister.
@MainActor
protocol TeleprompterShortcutControlling: AnyObject {
    func apply(enabled: Bool, modifiers: TeleprompterShortcutModifiers, action: @escaping (TeleprompterKeyboardAction) -> Void) -> Bool
}

@MainActor
final class TeleprompterGlobalShortcuts: TeleprompterShortcutControlling {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var action: ((TeleprompterKeyboardAction) -> Void)?
    private var pressState = TeleprompterShortcutPressState()
    static let bindings: [(UInt32, TeleprompterKeyboardAction)] = [
        (UInt32(kVK_ANSI_P), .playPause), (UInt32(kVK_UpArrow), .previousParagraph),
        (UInt32(kVK_DownArrow), .nextParagraph), (UInt32(kVK_ANSI_Equal), .faster),
        (UInt32(kVK_ANSI_Minus), .slower)
    ]

    func apply(enabled: Bool, modifiers: TeleprompterShortcutModifiers,
               action: @escaping (TeleprompterKeyboardAction) -> Void) -> Bool {
        stop()
        guard enabled else { return true }
        self.action = action
        var eventTypes = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4E585450 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<TeleprompterGlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                guard owner.pressState.shouldFire(id: identifier.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed)) else { return }
                let index = Int(identifier.id) - 1
                if TeleprompterGlobalShortcuts.bindings.indices.contains(index) { owner.action?(TeleprompterGlobalShortcuts.bindings[index].1) }
            }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { stop(); return false }
        for (index, binding) in Self.bindings.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x4E585450, id: UInt32(index + 1))
            let status = RegisterEventHotKey(binding.0, modifiers.carbonMask, identifier, GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else { stop(); return false }
            registrations.append(reference)
        }
        return true
    }

    func stop() {
        pressState = TeleprompterShortcutPressState()
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        action = nil
    }

    deinit {
        registrations.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
