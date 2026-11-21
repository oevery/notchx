import AppKit

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private static let showInScreenRecordingsDefaultsKey = "general.showInScreenRecordings"

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if QuitHotkeyGuard.shouldBlock(event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        let opensContextMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard opensContextMenu else {
            super.sendEvent(event)
            return
        }
        let name = IslandNativeAppearance.name(increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: nil) { notification in
                MainActor.assumeIsolated {
                    (notification.object as? NSMenu)?.appearance = NSAppearance(named: name)
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        super.sendEvent(event)
    }

    init() {
        let initialCompactSize = ScreenDetector.primaryScreen
            .flatMap(ScreenDetector.compactIslandMetrics(screen:))?
            .size ?? Constants.compactSize

        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: initialCompactSize.width,
                height: initialCompactSize.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false

        let shouldShowInRecordings = UserDefaults.standard.object(
            forKey: Self.showInScreenRecordingsDefaultsKey
        ) as? Bool ?? false
        setVisibleInScreenRecordings(shouldShowInRecordings)
    }

    func setVisibleInScreenRecordings(_ visible: Bool) {
        sharingType = visible ? .readOnly : .none
    }

    func setVisibleOnAllSpaces(_ visible: Bool) {
        var behavior = collectionBehavior
        if visible { behavior.insert(.canJoinAllSpaces) }
        else { behavior.remove(.canJoinAllSpaces) }
        if behavior != collectionBehavior { collectionBehavior = behavior }
    }
}
