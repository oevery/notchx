import AppKit
import SwiftUI

/// Only an explicit permission action can request restoration after a TCC restart.
final class SettingsPermissionReturn {
    private let defaults: UserDefaults
    private let key = "settings.permissionReturn"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(pane: SettingsPane, now: Date = Date()) {
        defaults.set(["pane": pane.id, "date": now.timeIntervalSince1970], forKey: key)
    }

    func take(now: Date = Date()) -> SettingsPane? {
        defer { cancel() }
        guard let saved = defaults.dictionary(forKey: key),
              let rawPane = saved["pane"] as? String,
              let timestamp = saved["date"] as? Double,
              (0...600).contains(now.timeIntervalSince1970 - timestamp) else { return nil }
        return SettingsPane(id: rawPane)
    }

    func cancel() { defaults.removeObject(forKey: key) }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedPane: SettingsPane? = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController(appState: .shared)
    private let appState: AppState
    private let permissionReturn = SettingsPermissionReturn()
    private var awaitingPermissionReturn = false
    private var handoff: (state: AppState, session: IslandPresentationHandoff)?

    init(appState: AppState) { self.appState = appState; super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(fromIsland appState: AppState? = nil, sourceWindow: NSWindow? = nil) {
        let context = appState.flatMap { IslandWindowContext(sourceWindow: sourceWindow, appState: $0) }
        if let appState {
            if let handoff, handoff.state !== appState {
                handoff.state.finishPresentationHandoff(handoff.session, outcome: .cancelled)
            }
            guard let session = appState.beginPresentationHandoff(.window, replacing: handoff?.session) else { return }
            handoff = (appState, session)
        }
        if window == nil {
            let root = SettingsView().environmentObject(self.appState).notchXLocalized()
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 680))
            window.minSize = NSSize(width: 800, height: 560)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = L10n.text("NotchX Settings")
        if let window { window.minSize = IslandWindowPlacement.minimumFrameSize(for: window, contentMinimum: NSSize(width: 800, height: 560)) }
        if let window, let context {
            let frame = IslandWindowPlacement.frame(size: window.frame.size, savedFrame: window.frame,
                visibleFrame: context.screen.visibleFrame, islandFrame: context.islandFrame,
                minimumSize: window.minSize)
            window.setFrame(frame, display: false)
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func beginPermissionRequest() {
        guard window?.isVisible == true else { return }
        awaitingPermissionReturn = true
        permissionReturn.begin(pane: SettingsNavigation.shared.selectedPane ?? .general)
    }

    func restoreAfterPermissionReturn(isLaunching: Bool = false) {
        guard isLaunching || awaitingPermissionReturn else { return }
        awaitingPermissionReturn = false
        guard let pane = permissionReturn.take() else { return }
        // Keep the existing view tree (including its scroll position) on ordinary returns.
        if isLaunching { SettingsNavigation.shared.selectedPane = pane }
        show()
    }

    func windowWillClose(_ notification: Notification) {
        if let handoff { handoff.state.finishPresentationHandoff(handoff.session, outcome: .cancelled) }
        handoff = nil
        awaitingPermissionReturn = false
        permissionReturn.cancel()
    }
}
