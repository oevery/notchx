import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private let window: NSWindow
    private var languageObserver: NSObjectProtocol?

    init(onComplete: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingLayout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.text("NotchX Setup")
        window.minSize = OnboardingLayout.windowSize
        window.maxSize = OnboardingLayout.windowSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            onComplete: onComplete, onOpenSettings: onOpenSettings
        ))
        languageObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.window.title = L10n.text("NotchX Setup") }
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    func show() {
        window.title = L10n.text("NotchX Setup")
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func close() { window.orderOut(nil) }
}
