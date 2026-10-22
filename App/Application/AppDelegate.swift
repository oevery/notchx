import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandWindowController: IslandWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var menuBarDefaultsObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var quitHotkeyMonitor: Any?
    private var didBootstrapApp = false
    private let moduleRegistry = NativeModuleRegistry()
    private var modulePresentationBridge: ModulePresentationBridge?
    private var isUnitTestHost: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NOTCHX_UNIT_TEST_HOST"] == "1"
        #else
        return false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        installQuitHotkeyMonitor()

        // defaults write app.notchx "debug.alwaysShowOnboarding" -bool true
        let shouldShowOnboarding = !AppState.shared.onboardingCompleted || AppState.shared.debugAlwaysShowOnboarding
        if shouldShowOnboarding {
            showOnboardingIfNeeded()
        } else {
            bootstrapApp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        didBootstrapApp = false
        modulePresentationBridge?.stop()
        modulePresentationBridge = nil
        AppState.shared.moduleEnablementDidChange = nil
        AppState.shared.moduleEnablementWillChange = nil
        AppState.shared.presentationPreferencesDidChange = nil
        moduleRegistry.shutdown()
        AppState.shared.refreshScheduler = nil
        ModuleRefreshScheduler.shared.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        SettingsWindowController.shared.restoreAfterPermissionReturn()
        AppState.shared.setAppActive(true)
        if didBootstrapApp {
            activateModules(refreshPermissions: true)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        AppState.shared.setAppActive(false)
    }

    deinit {
        if let quitHotkeyMonitor {
            NSEvent.removeMonitor(quitHotkeyMonitor)
        }
        if let menuBarDefaultsObserver {
            NotificationCenter.default.removeObserver(menuBarDefaultsObserver)
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    private func bootstrapApp() {
        guard !didBootstrapApp else { return }
        didBootstrapApp = true
        initializeManagers()
        setupIslandWindow()
        applyMenuBarVisibility()
        observeMenuBarSetting()
        observePowerState()
        SettingsWindowController.shared.restoreAfterPermissionReturn(isLaunching: true)
    }

    private func showOnboardingIfNeeded() {
        applyMenuBarVisibility()
        observeMenuBarSetting()

        // LSUIElement apps can't reliably bring windows to the front.
        // Temporarily become a regular app so the onboarding window appears.
        NSApp.setActivationPolicy(.regular)

        guard onboardingWindowController == nil else {
            onboardingWindowController?.show()
            return
        }

        onboardingWindowController = OnboardingWindowController { [weak self] in
            self?.completeOnboarding()
        } onOpenSettings: {
            Self.showSettingsWindow()
        }
        onboardingWindowController?.show()
    }

    private func completeOnboarding() {
        AppState.shared.onboardingCompleted = true
        onboardingWindowController?.close()
        onboardingWindowController = nil

        // Revert to agent app (no dock icon) now that onboarding is done.
        NSApp.setActivationPolicy(.accessory)
        bootstrapApp()
    }

    // MARK: - Manager Initialization

    private func initializeManagers() {
        let state = AppState.shared
        state.refreshScheduler = .shared
        modulePresentationBridge = ModulePresentationBridge(state: state)
        state.moduleEnablementDidChange = { [weak self] in self?.activateModules() }
        state.moduleEnablementWillChange = { module, enabled in
            module != .tools || enabled || ToolsManager.shared.setEnabled(false)
        }
        state.presentationPreferencesDidChange = { [weak state] in
            if state?.calendarEnabled == true { CalendarManager.shared.refreshReminderSchedule() }
        }
        activateModules()
        rebuildStatusMenu()
        state.refreshEnergyState()

    }

    private func activateModules(refreshPermissions: Bool = false) {
        let state = AppState.shared
        // Connect before start, disconnect before stop, so initial events are not lost.
        modulePresentationBridge?.reconcile()
        moduleRegistry.activateEnabledModules(in: state, refreshPermissions: refreshPermissions) { [weak self] in
            self?.configurePresentation(for: $0, state: state)
        }
        state.refreshEnergyState()
    }

    private func configurePresentation(for module: ModuleType, state: AppState) {
        switch module {
        case .nowPlaying:
            NowPlayingManager.shared.onPlaybackAvailable = { [weak state] in state?.setActiveModule(.nowPlaying) }
        case .volumeHUD:
            VolumeManager.shared.onVolumeChanged = { [weak state] in state?.presentEvent(.volume) }
        case .battery:
            BatteryManager.shared.lowBatteryThreshold = { [weak state] in state?.presentationPreferences.lowBatteryThreshold ?? 20 }
            BatteryManager.shared.onPowerEvent = { [weak state] in state?.presentEvent($0) }
            BatteryManager.shared.onBatteryPower = { EnergySuggestionPresenter.shared.suggestLowPower(reason: .battery) }
        case .connectivity:
            BluetoothManager.shared.onConnectionChanged = { [weak state] id, connected in
                guard let state, !state.presentationPreferences.ignoredBluetoothDeviceIDs.contains(id) else { return }
                state.presentEvent(connected ? .bluetoothConnected : .bluetoothDisconnected)
            }
        case .calendar:
            let manager = CalendarManager.shared
            manager.remindersEnabled = { [weak state] in state?.presentationPreferences[.calendarReminder].enabled == true }
            manager.onReminderPresented = { [weak state] in state?.presentEvent(.calendarReminder) }
            manager.onReminderCleared = { [weak state] in state?.clearPendingEvents(for: .calendar) }
            manager.onReminderSnoozed = { [weak state] in
                if state?.currentState == .expanded, state?.activeBuiltInModule == .calendar { state?.dismiss() }
            }
        default: break
        }
    }

    private func installQuitHotkeyMonitor() {
        guard quitHotkeyMonitor == nil else { return }

        quitHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            QuitHotkeyGuard.shouldBlock(event) ? nil : event
        }
    }

    // MARK: - Island Window

    private func setupIslandWindow() {
        islandWindowController = IslandWindowController()
        islandWindowController?.showIsland()
    }

    // MARK: - Menu Bar

    private func applyMenuBarVisibility() {
        if AppState.shared.showMenuBarIcon {
            installStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: Constants.menuBarIconName, accessibilityDescription: "NotchX")
        }

        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        item.menu = buildStatusMenu()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "Now Playing", action: #selector(showNowPlaying)))
        menu.addItem(makeMenuItem(title: "Battery", action: #selector(showBattery)))
        menu.addItem(NSMenuItem.separator())

        let modulesItem = NSMenuItem(title: L10n.text("Modules"), action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu()

        for module in AppState.shared.orderedModules {
            let moduleItem = NSMenuItem(title: L10n.text(module.displayName), action: #selector(toggleModule(_:)), keyEquivalent: "")
            moduleItem.target = self
            moduleItem.representedObject = module.rawValue
            moduleItem.state = AppState.shared.isModuleEnabled(module) ? .on : .off
            moduleItem.image = NSImage(systemSymbolName: module.iconName, accessibilityDescription: module.displayName)
            modulesMenu.addItem(moduleItem)
        }

        modulesItem.submenu = modulesMenu
        menu.addItem(modulesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Quit NotchX", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func observeMenuBarSetting() {
        guard menuBarDefaultsObserver == nil else { return }
        menuBarDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppState.shared.objectWillChange.send()
                self?.applyMenuBarVisibility()
                if self?.didBootstrapApp == true {
                    self?.activateModules()
                    self?.rebuildStatusMenu()
                }
                ModuleRefreshScheduler.shared.refreshScheduling()
            }
        }
    }

    private func observePowerState() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppState.shared.refreshEnergyState()
            }
        }
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu Actions

    @objc private func showNowPlaying() {
        AppState.shared.showHUD(module: .nowPlaying, autoDismiss: false)
    }

    @objc private func showBattery() {
        AppState.shared.showHUD(module: .battery, autoDismiss: false)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = ModuleType(rawValue: rawValue) else { return }

        let newState = !AppState.shared.isModuleEnabled(module)
        AppState.shared.setModuleEnabled(module, enabled: newState)
        sender.state = newState ? .on : .off
        rebuildStatusMenu()
    }

    @objc private func openSettings() {
        // NSStatusItem menu actions run while the menu is still tracking.
        // Defer window presentation to the next runloop tick so it reliably appears.
        DispatchQueue.main.async {
            Self.showSettingsWindow()
        }
    }

    static func showSettingsWindow(fromIsland appState: AppState? = nil) {
        // Avoid opening the SwiftUI Settings scene via AppKit selectors in menu-bar mode.
        // macOS may reject those calls with a "use SettingsLink" warning.
        SettingsWindowController.shared.show(fromIsland: appState, sourceWindow: NSApp.currentEvent?.window)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
