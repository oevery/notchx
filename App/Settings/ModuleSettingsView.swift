import AppKit
import AVFoundation
import EventKit
import Speech
import SwiftUI
import UserNotifications

/// Compiled-in modules share AppState's persisted enablement switches.
extension ModuleType {
    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .volumeHUD: return "Volume HUD"
        case .battery: return "Battery"
        case .shelf: return "Shelf"
        case .connectivity: return "Connectivity"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .notifications: return "Notifications"
        case .teleprompter: return "Teleprompter"
        case .agent: return "Agent"
        case .tools: return "Tools"
        }
    }
    var icon: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .volumeHUD: return "speaker.wave.2"
        case .battery: return "battery.100"
        case .shelf: return "tray"
        case .connectivity: return "wifi"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .notifications: return "bell"
        case .teleprompter: return "text.alignleft"
        case .agent: return "terminal"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    @MainActor
    func enabledBinding(in appState: AppState) -> Binding<Bool> {
        Binding(
            get: { appState.isModuleEnabled(self) },
            set: { appState.setModuleEnabled(self, enabled: $0) }
        )
    }
}

struct ModuleSettingsView: View {
    @ObservedObject var appState: AppState
    let showDetails: (ModuleType) -> Void

    var body: some View {
        ModuleSettingsContent(appState: appState, showDetails: showDetails)
            .id(ObjectIdentifier(appState))
    }
}

/// The transaction and its undo history belong to one AppState instance.
private struct ModuleSettingsContent: View {
    @ObservedObject var appState: AppState
    @StateObject private var restoreSession: SettingsRestoreSession
    let showDetails: (ModuleType) -> Void

    init(appState: AppState, showDetails: @escaping (ModuleType) -> Void) {
        self.appState = appState
        self.showDetails = showDetails
        _restoreSession = StateObject(wrappedValue: SettingsRestoreSession(appState: appState))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSupportingText("Turn each module on or off independently. Choose Details to configure it.")
            SettingSupportingText("Drag rows to reorder navigation. This does not change notification priority or Home layout.")
            SettingGroup {
                ModuleManagementList(appState: appState, showDetails: showDetails)
            }
            SettingGroup {
                SettingRestoreRow(description: SettingsRestoreScope.moduleOrder.description, buttonTitle: "Restore Default Order",
                    undo: restoreSession.canUndo(.moduleOrder) ? { restoreSession.undo(.moduleOrder) } : nil) {
                        restoreSession.restoreGroup(.moduleOrder)
                    }
                    .padding(.leading, 36) // Align restore copy with module titles, past the handles.
            }
        }
        .onChange(of: appState.orderedModules) { _, _ in
            restoreSession.discardUndoIfChanged(.moduleOrder)
        }
        .environmentObject(appState)
    }
}

struct ModuleDetailSettingsView: View {
    @ObservedObject var appState: AppState
    let module: ModuleType

    init(module: ModuleType, appState: AppState) {
        self.appState = appState
        self.module = module
    }

    var body: some View {
        ModuleDetailSettingsContent(module: module, appState: appState)
            .id(module)
            .id(ObjectIdentifier(appState))
    }
}

/// Replacing the owner or module also discards any pending confirmation.
private struct ModuleDetailSettingsContent: View {
    @ObservedObject var appState: AppState
    let module: ModuleType
    @StateObject private var restoreSession: SettingsRestoreSession

    init(module: ModuleType, appState: AppState) {
        self.appState = appState
        self.module = module
        _restoreSession = StateObject(wrappedValue: SettingsRestoreSession(appState: appState))
    }

    private var restoreScope: SettingsRestoreScope { .module(module) }
    @State private var showRestoreConfirmation = false
    @State private var resetGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingPageHeader(title: L10n.text(module.title)) {
                SettingSwitch(title: "Enable module", isOn: module.enabledBinding(in: appState))
                    .dataAnnotationID(module == .teleprompter ? "teleprompter-module-toggle" : "module-detail-toggle-\(module.rawValue)")
            }
            if module.enabledBinding(in: appState).wrappedValue || module == .agent {
                moduleDetails
            } else {
                SettingGroup {
                    SettingNote("This module is off. Enable it to configure its settings. Your preferences are kept.")
                }
            }
            if !restoreScope.entries.isEmpty { ModuleRestoreDefaultsRow(action: requestRestore) }
        }
        .alert(L10n.format("Restore %@ Settings?", L10n.text(module.title)), isPresented: $showRestoreConfirmation) {
            Button(L10n.text("Cancel"), role: .cancel) { restoreSession.cancelModuleRestore() }
            Button(L10n.text("Restore Module Defaults")) {
                resetGeneration += 1
                restoreSession.confirmModuleRestore()
            }
        } message: {
            Text(restoreScope.description + "\n\n" + L10n.text("Only this module’s preferences will change. Module enablement, other modules, Home layout, and user content are kept. No permissions will be requested."))
        }
        .onChange(of: showRestoreConfirmation) { _, presented in
            if !presented { restoreSession.cancelModuleRestore() }
        }
        .environment(\.settingResetGeneration, resetGeneration)
        .onDisappear { restoreSession.cancelModuleRestore() }
        .environmentObject(appState)
    }

    private func requestRestore() {
        restoreSession.requestModuleRestore(module)
        showRestoreConfirmation = true
    }

    // Only construct the selected module. Agent retains explicit Hook management
    // while disabled; its manager does not start sources from this view.
    @ViewBuilder private var moduleDetails: some View {
        switch module {
        case .nowPlaying: NowPlayingSettingsDetail()
        case .shelf: ShelfSettingsDetail()
        case .calendar: CalendarSettingsDetail()
        case .weather: WeatherSettingsDetail(preferences: appState.weatherPreferences)
        case .notifications: NotificationSettingsDetail()
        case .teleprompter: TeleprompterSettingsDetail()
        case .agent: AgentSettingsDetail()
        case .tools:
            ToolsSettingsDetail()
        case .volumeHUD: VolumeSettingsDetail()
        case .battery: BatterySettingsDetail()
        case .connectivity: ConnectivitySettingsDetail()
        }
    }
}

/// A shared final row keeps the restore affordance aligned with module controls.
struct ModuleRestoreDefaultsRow: View {
    let action: () -> Void

    var body: some View {
        SettingGroup {
            SettingRestoreRow(buttonTitle: "Restore Module Defaults…", identifier: "settings-module-restore", action: action)
        }
    }
}

struct HomeLayoutSettingsView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSupportingText("Choose where panels appear. Module switches are managed separately in Modules.")
            SettingGroup {
                homeSlotRow(title: "Left slot", selection: $appState.homeLeadingPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Center slot", selection: $appState.homeCenterPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Right slot", selection: $appState.homeTrailingPanelRaw)
            }
        }
    }
    private func homeSlotRow(title: String, selection: Binding<String>) -> some View {
        SettingPickerRow(title: title, selection: selection) {
            ForEach(HomePanel.allCases) { panel in
                Label(L10n.text(panel.title), systemImage: panel.iconName).tag(panel.rawValue)
            }
        }
    }

}

private struct NowPlayingSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var nowPlayingManager = NowPlayingManager.shared
    @State private var installedPlayers: Set<String> = []
    @State private var automationGranted: Set<String> = []
    @State private var accessibilityGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSectionLabel(title: "Music display")
            SettingGroup {
                SettingToggleRow(title: "Show music in compact mode", description: "The playback page and Home music card remain available when this is off.", isOn: $appState.compactMusicEnabled)
                SettingRowDivider()
                SettingPickerRow(title: "Keep music after pausing",
                    description: "Only affects compact music. Open pages stay in place; brief loading pauses are filtered automatically.",
                    selection: $nowPlayingManager.pauseRetentionSeconds) {
                        Text("Immediately hide").tag(0)
                        Text("5 seconds").tag(5)
                        Text("15 seconds").tag(15)
                        Text("Always retain paused music").tag(-1)
                    }
                    .disabled(!appState.compactMusicEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Album artwork glow", description: "Use the cover colors behind album artwork.", isOn: $appState.musicArtworkGlowEnabled)
                SettingRowDivider()
                SettingNote("Track changes update music without switching away from your current page. Fullscreen and animation behavior follow the general settings.")
            }
            SettingSectionLabel(title: "Players and permissions")
            SettingGroup {
                currentPlayerRow
                if isInstalled("com.netease.163music") {
                    SettingRowDivider()
                    netEasePermissionRow
                }
                if isInstalled("com.spotify.client") {
                    SettingRowDivider()
                    automationPermissionRow(title: "Spotify", bundleIdentifier: "com.spotify.client")
                }
                if isInstalled("com.apple.Music") {
                    SettingRowDivider()
                    automationPermissionRow(title: "Music", bundleIdentifier: "com.apple.Music")
                }
                if isInstalled("com.spotify.client") || isInstalled("com.apple.Music") || nowPlayingManager.browserDetectionEnabled {
                    SettingRowDivider()
                    automationPermissionRow(title: "System Events", bundleIdentifier: "com.apple.systemevents", explanation: "Used with player automation to check running apps. Basic system media playback does not require granting every permission here.")
                }
            }
            SettingSectionLabel(title: "Browser media")
            SettingGroup {
                SettingToggleRow(title: "Browser media detection", description: "Adds browser tab detection using automation. Turning this off does not block media reported by macOS.", isOn: $nowPlayingManager.browserDetectionEnabled)
                if nowPlayingManager.browserDetectionEnabled { browserMediaRows }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func isInstalled(_ bundleIdentifier: String) -> Bool {
        installedPlayers.contains(bundleIdentifier)
    }

    private func refreshPermissions() {
        let targets = ["com.netease.163music", "com.spotify.client", "com.apple.Music"] + nowPlayingManager.browserTargets.map(\.id)
        installedPlayers = Set(targets.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        automationGranted = Set(installedPlayers.union(["com.apple.systemevents"]).filter {
            $0 != "com.netease.163music" && PermissionsManager.hasAutomationAccess(to: $0)
        })
        accessibilityGranted = PermissionsManager.shared.checkAccessibility()
    }

    private var currentPlayerRow: some View {
        SettingContent {
            Text("Current player").font(.headline)
            Text(nowPlayingManager.hasControllableTrack ? nowPlayingManager.sourceName : L10n.text("No active player"))
            if nowPlayingManager.hasControllableTrack {
                SettingSupportingText(L10n.text("Playback controls") + (nowPlayingManager.canSeek ? " · " + L10n.text("Seek") : ""))
                if nowPlayingManager.shuffleMode != nil || nowPlayingManager.repeatMode != nil {
                    SettingSupportingText("Playback modes reported by this player are shown automatically.")
                }
            }
            SettingSupportingText("Controls appear only when the current player provides the required capability. Favorites are currently supported for NetEase Cloud Music.")
        }
    }

    private var netEasePermissionRow: some View {
        let granted = accessibilityGranted
        return SettingPermissionRow(title: "NetEase favorites",
                          description: "Reading and changing favorites requires Accessibility access. Basic playback uses system media controls.", isGranted: granted) {
            Button("Open Settings") {
                SettingsWindowController.shared.beginPermissionRequest()
                PermissionsManager.shared.openAccessibilitySettings()
            }
        }
    }
    @ViewBuilder
    private var browserMediaRows: some View {
        ForEach(nowPlayingManager.browserTargets.filter { isInstalled($0.id) }) { browser in
            SettingRowDivider()
            browserToggleRow(browser)
            if nowPlayingManager.isBrowserAllowed(browser.id) {
                automationPermissionRow(title: browser.displayName, bundleIdentifier: browser.id, explanation: "Browser tab detection requires Automation access and JavaScript from Apple Events in the browser.")
            }
        }
        SettingRowDivider()
        browserDetectionTestRow
    }

    private func automationPermissionRow(title: String, bundleIdentifier: String, explanation: String = "Optional player automation fallback. Open the app before granting access; permission is requested only when you click Grant Access.") -> some View {
        let granted = automationGranted.contains(bundleIdentifier)
        return SettingPermissionRow(title: L10n.format("%@ automation", L10n.text(title)), description: explanation, isGranted: granted) {
            Button("Grant Access") {
                SettingsWindowController.shared.beginPermissionRequest()
                _ = PermissionsManager.requestAutomationAccess(to: bundleIdentifier)
                refreshPermissions()
            }
            Button("Open Settings") {
                SettingsWindowController.shared.beginPermissionRequest()
                nowPlayingManager.openAutomationSettings()
            }
        }
    }

    private func browserToggleRow(_ browser: NowPlayingBrowserTarget) -> some View {
        SettingToggleRow(
            title: browser.displayName,
            description: "Allow NotchX to look for media in this browser.",
            isOn: browserBinding(for: browser.id)
        )
    }

    private var browserDetectionTestRow: some View {
        SettingRow(title: "Detection test", description: browserDetectionMessage) {
            SettingActions {
                Button("Test") { nowPlayingManager.testBrowserDetection() }
                Button("Open Settings") {
                    SettingsWindowController.shared.beginPermissionRequest()
                    nowPlayingManager.openAutomationSettings()
                }
            }
        }
    }

    private func browserBinding(for browserID: String) -> Binding<Bool> {
        Binding(
            get: { nowPlayingManager.isBrowserAllowed(browserID) },
            set: { nowPlayingManager.setBrowser(browserID, allowed: $0) }
        )
    }

    private var browserDetectionMessage: String {
        if !nowPlayingManager.browserDetectionTestMessage.isEmpty {
            return nowPlayingManager.browserDetectionTestMessage
        }
        return L10n.text("Requires Automation permission and JavaScript from Apple Events in the browser.")
    }
}

private struct ShelfSettingsDetail: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shelf = ShelfStore.shared
    var body: some View {
        SettingGroup {
            SettingToggleRow(title: "Expand Shelf early while dragging",
                             description: "Open Shelf when dragged items approach the island, before reaching the screen edge.",
                             isOn: $appState.shelfExpandOnDragApproach)
                .accessibilityIdentifier("settings-shelf-drag-approach")
            SettingRowDivider()
            SettingToggleRow(title: "Auto-open Shelf on Drop", isOn: $appState.shelfAutoOpenOnDrop)
            SettingRowDivider()
            shelfRetentionRow
        }
    }
    private var shelfRetentionRow: some View {
        SettingPickerRow(title: "Shelf retention", description: "Pinned items are kept", selection: $shelf.retentionDays) {
            ForEach(ShelfRetentionOption.allCases) { option in Text(L10n.text(option.title)).tag(option.rawValue) }
        }
    }

}

private struct CalendarSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var calendarManager = CalendarManager.shared
    var body: some View {
        IslandEventSettings(module: .calendar, reminderLeadTime: Binding(get: { calendarManager.preEventMinutes }, set: { calendarManager.preEventMinutes = $0 }))
        SettingGroup {
            calendarPermissionRow
            if calendarManager.hasAccess {
                SettingRowDivider()
                calendarLookaheadRow
                SettingRowDivider()
                SettingDisclosureGroup(title: "Calendars and filtering") {
                    SettingToggleRow(title: "Collapse duplicate events", description: "Hide repeated holidays or birthdays with the same title and time.", isOn: $calendarManager.collapseDuplicates)
                    SettingToggleRow(title: "Hide holidays", isOn: $calendarManager.hideHolidays)
                    SettingToggleRow(title: "Hide birthdays", isOn: $calendarManager.hideBirthdays)
                    calendarSourceRows
                }
            }
        }
        .onAppear { calendarManager.refreshAccessStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarManager.refreshAccessStatus()
        }
    }
    private var calendarPermissionRow: some View {
        SettingPermissionRow(title: "Calendar access", description: calendarPermissionDescription, isGranted: calendarManager.hasAccess) {
            Button(L10n.text(calendarPermissionButtonTitle)) { handleCalendarPermissionAction() }
        }
    }

    private var calendarLookaheadRow: some View {
        SettingNumberRow(title: "Upcoming range", description: "How many days appear in the Upcoming column.",
                         value: calendarLookaheadBinding, step: 1, range: 1...30, unit: "d")
    }

    @ViewBuilder
    private var calendarSourceRows: some View {
        if calendarManager.calendarSourceGroups.isEmpty {
            SettingRowDivider()
            SettingNote("No calendars available")
        } else {
            ForEach(calendarManager.calendarSourceGroups) { group in
                SettingRowDivider()
                SettingNote(group.title, localizesText: false)

                ForEach(group.calendars) { calendar in
                    calendarSourceRow(calendar)
                    if calendar.id != group.calendars.last?.id {
                        SettingRowDivider()
                    }
                }
            }
        }
    }

    private func calendarSourceRow(_ calendar: CalendarDisplayOption) -> some View {
        SettingRow(title: calendar.title, description: calendarTypeLabel(calendar.type), localizesTitle: false) {
            Circle().fill(Color(cgColor: calendar.color)).frame(width: 9, height: 9).accessibilityHidden(true)
            SettingSwitch(title: calendar.title, isOn: calendarEnabledBinding(for: calendar.id), localizesTitle: false)
        }
    }

    private var calendarLookaheadBinding: Binding<Double> {
        Binding(
            get: { Double(calendarManager.lookaheadDays) },
            set: { calendarManager.lookaheadDays = Int($0) }
        )
    }

    private var calendarPermissionDescription: String {
        switch calendarManager.authorizationStatus {
        case .fullAccess:
            return L10n.text("Allowed. Choose which calendars appear in NotchX.")
        case .notDetermined:
            return L10n.text("Not requested. Allow access to show upcoming events.")
        case .denied:
            return L10n.text("Denied. Open System Settings to allow Calendar access.")
        case .restricted:
            return L10n.text("Restricted by macOS settings.")
        case .writeOnly:
            return L10n.text("Write-only access is not enough to display events.")
        @unknown default:
            return L10n.text("Unknown. Check macOS Calendar privacy settings.")
        }
    }

    private var calendarPermissionButtonTitle: String {
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            return L10n.text("Request")
        default:
            return L10n.text("Open Settings")
        }
    }

    private func handleCalendarPermissionAction() {
        SettingsWindowController.shared.beginPermissionRequest()
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            calendarManager.requestAccess()
        default:
            calendarManager.openCalendarSettings()
        }
    }

    private func calendarTypeLabel(_ type: CalendarKind) -> String {
        switch type {
        case .local:
            return L10n.text("Local")
        case .calDAV:
            return "CalDAV"
        case .exchange:
            return "Exchange"
        case .subscription:
            return L10n.text("Subscription")
        case .birthday:
            return L10n.text("Birthdays")
        case .unknown:
            return L10n.text("Calendar")
        }
    }

    private func calendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { calendarManager.isCalendarEnabled(calendarID) },
            set: { calendarManager.setCalendar(calendarID, enabled: $0) }
        )
    }

}

private struct WeatherSettingsDetail: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var manager = WeatherManager.shared
    @ObservedObject var preferences: WeatherPreferences
    @State private var cityQuery = ""
    @State private var choosingCity = false
    var body: some View {
        SettingSectionLabel(title: "Location")
        SettingGroup {
            SettingPickerRow(title: "Location mode", selection: manualLocation) {
                Text("Current location").tag(false)
                Text("Selected city").tag(true)
            }
            if manualLocation.wrappedValue {
                SettingRowDivider()
                SettingContent {
                    if let city = manager.selectedCity { Text(city.label).font(.headline) }
                    SettingSearchField(title: "Search for a city", query: $cityQuery, isSearching: manager.isSearchingCities) {
                        manager.searchCities(cityQuery)
                    }
                    if manager.isSearchingCities { ProgressView().controlSize(.small) }
                    if let error = manager.citySearchError { SettingSupportingText(verbatim: error) }
                    ForEach(manager.cityResults) { city in
                        Button(city.label) { manager.selectCity(city) }.buttonStyle(.borderless)
                    }
                }
            } else {
                SettingNote(manager.locationStatusDescription, localizesText: false)
                if manager.authorizationStatus != .authorizedAlways {
                    SettingActionRow(title: "Location access",
                        buttonTitle: manager.authorizationStatus == .notDetermined ? "Grant Access" : "Open Settings") {
                            SettingsWindowController.shared.beginPermissionRequest()
                            if manager.authorizationStatus == .notDetermined { manager.requestLocationAndFetch() }
                            else { PermissionsManager.shared.openLocationSettings() }
                        }
                }
            }
        }
        .onDisappear { manager.cancelCitySearch() }
        SettingSectionLabel(title: "Units")
        SettingGroup {
            SettingPickerRow(title: "Temperature Unit", selection: $preferences.temperatureUnit, segmented: true) {
                Text("°C").tag(TemperatureUnit.celsius)
                Text("°F").tag(TemperatureUnit.fahrenheit)
            }
            SettingRowDivider()
            SettingPickerRow(title: "Wind speed unit", selection: $preferences.windUnit) {
                ForEach(WeatherWindUnit.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var manualLocation: Binding<Bool> {
        Binding(get: { manager.selectedCity != nil || choosingCity }, set: { manual in
            choosingCity = manual
            if !manual { manager.cancelCitySearch(); manager.selectCity(nil) }
        })
    }
}

private struct NotificationSettingsDetail: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var notificationManager = NotificationManager.shared
    var body: some View {
        IslandEventSettings(module: .notifications)
        SettingSectionLabel(title: "Privacy and filtering")
        SettingGroup {
            SettingToggleRow(title: "Show previews", description: "Display sender and message text when available.",
                             isOn: notificationPreviewsBinding, identifier: "settings-notification-previews")
            SettingRowDivider()
            notificationRetentionRow
            SettingRowDivider()
            SettingDisclosureGroup(title: "Application filters") {
                if notificationManager.knownApplications.isEmpty {
                    SettingNote("Applications appear here after their first supported notification.")
                }
                ForEach(notificationManager.knownApplications) { app in
                    SettingToggleRow(title: L10n.format("Show %@ notifications", app.name), isOn: Binding(
                        get: { !notificationManager.mutedApplicationIDs.contains(app.id) },
                        set: { notificationManager.setApplicationMuted(app.id, muted: !$0) }))
                }
            }
        }
        SettingGroup {
            SettingDisclosureGroup(title: "Compatibility and permissions") {
                ForEach(NotificationFeedSource.allCases) { source in
                    SettingToggleRow(title: source.title, description: source.description, isOn: notificationSourceBinding(for: source))
                }
                SettingNote("The feed supports compatible app broadcasts and existing WhatsApp observation paths. It does not read every macOS notification.")
                SettingNote("Notification permission only allows NotchX to send its own alerts. Clearing removes items from NotchX only; clicking opens the source app.")
                notificationPermissionRow
            }
        }
        .onAppear { notificationManager.checkPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationManager.checkPermission()
        }
    }
    private var notificationPermissionRow: some View {
        SettingActionRow(title: "Permission", description: notificationPermissionDescription,
                         buttonTitle: notificationPermissionButtonTitle, action: handleNotificationPermissionAction)
    }

    private var notificationRetentionRow: some View {
        SettingNumberRow(title: "Retained items", description: "How many feed items stay available in the island.",
                         value: notificationMaxRetainedBinding, step: 1, range: 1...50, unit: "")
    }

    private var notificationPreviewsBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationPreviewsEnabled },
            set: { newValue in
                appState.notificationPreviewsEnabled = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationMaxRetainedBinding: Binding<Double> {
        Binding(
            get: { appState.notificationMaxRetainedItems },
            set: { newValue in
                appState.notificationMaxRetainedItems = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private func notificationSourceBinding(for source: NotificationFeedSource) -> Binding<Bool> {
        Binding(
            get: { appState.isNotificationSourceEnabled(source) },
            set: { newValue in
                appState.setNotificationSource(source, enabled: newValue)
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationPermissionDescription: String {
        switch notificationManager.authorizationStatus {
        case .authorized:
            return L10n.text("Allowed. NotchX can send its own notifications.")
        case .denied:
            return L10n.text("Denied. Open System Settings to allow NotchX notifications.")
        case .notDetermined:
            return L10n.text("Not requested. Allow this when you want NotchX to send macOS notifications.")
        case .provisional, .ephemeral:
            return L10n.text("Allowed with limited delivery.")
        @unknown default:
            return L10n.text("Unknown. Check macOS notification settings.")
        }
    }

    private var notificationPermissionButtonTitle: String {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            return L10n.text("Request")
        default:
            return L10n.text("Open Settings")
        }
    }

    private func handleNotificationPermissionAction() {
        SettingsWindowController.shared.beginPermissionRequest()
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            notificationManager.requestPermission()
        default:
            notificationManager.openNotificationSettings()
        }
    }

}

private struct TeleprompterSettingsDetail: View {
    @ObservedObject private var teleprompter = TeleprompterManager.shared
    @ObservedObject private var permissions = PermissionState.shared
    var body: some View {
        SettingGroup {
            SettingPickerRow(title: "Mode", description: teleprompter.listeningMode.description,
                             selection: $teleprompter.listeningMode, segmented: true, identifier: "teleprompter-listening-mode-control") {
                ForEach(TeleprompterListeningMode.allCases) { mode in Text(L10n.text(mode.label)).tag(mode) }
            }
            if teleprompter.listeningMode == .wordTracking {
                SettingRowDivider()
                teleprompterPermissionRow
            }
        }
        SettingSectionLabel(title: "Reading layout")
        SettingGroup {
            SettingSliderRow(title: "Reading column", value: $teleprompter.columnWidth, range: 0.5...1, step: 0.05) {
                L10n.format("%d%%", Int($0 * 100))
            }
            SettingRowDivider()
            SettingToggleRow(title: "Show reading guide", isOn: $teleprompter.showsReadingGuide)
            SettingRowDivider()
            SettingSliderRow(title: "Reading guide position", value: $teleprompter.readingGuidePosition, range: 0.2...0.7, step: 0.05) {
                L10n.format("%d%%", Int($0 * 100))
            }
            SettingRowDivider()
            SettingNumberRow(title: "Countdown", value: .settingInteger($teleprompter.countdownSeconds),
                             step: 1, range: 0...10, unit: "s", identifier: "settings-teleprompter-countdown")
        }
        SettingGroup {
            SettingDisclosureGroup(title: "Keyboard shortcuts") {
                SettingToggleRow(title: "Global prompter shortcuts", isOn: $teleprompter.globalShortcutsEnabled)
                if teleprompter.globalShortcutsEnabled {
                    SettingPickerRow(title: "Shortcut modifiers", selection: $teleprompter.shortcutModifiers) {
                        ForEach(TeleprompterShortcutModifiers.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    SettingNote("Use the selected modifiers with P to play/pause, Up/Down to change paragraph, and +/− to change speed. Shortcuts work in other apps while this module is enabled.")
                    if teleprompter.globalShortcutConflict {
                        SettingNote("A shortcut is already in use. Choose different modifiers; no global prompter shortcuts are active.")
                    }
                }
                SettingNote("While the prompter page is active: Space plays or pauses, Esc pauses, +/− changes speed, and Up/Down selects a paragraph. Text editing and modified shortcuts are not intercepted.")
            }
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
        .onChange(of: teleprompter.listeningMode) { _, _ in
            Task { await permissions.refresh() }
        }
    }
    private var teleprompterPermissionRow: some View {
        let ready = permissions.snapshot?.granted.isSuperset(of: [.microphone, .speechRecognition]) == true

        return SettingPermissionRow(title: "Word Tracking permissions", description: teleprompterPermissionDescription,
                                    isGranted: ready, grantedTitle: "Ready") {
            Button(L10n.text(teleprompterPermissionButtonTitle)) {
                requestTeleprompterPermissions()
            }
        }
        .dataAnnotationID("teleprompter-speech-status")
    }

    private var teleprompterPermissionDescription: String {
        let microphoneStatus = permissions.snapshot?.microphone ?? .notDetermined
        let speechStatus = permissions.snapshot?.speech ?? .notDetermined
        let microphone = microphoneStatus == .authorized
        let speech = speechStatus == .authorized

        if microphoneStatus == .denied || microphoneStatus == .restricted ||
            speechStatus == .denied || speechStatus == .restricted {
            return L10n.text("Access was denied or restricted. Open System Settings to enable Word Tracking.")
        }

        switch (microphone, speech) {
        case (true, true):
            return L10n.text("Microphone and Speech Recognition are ready for Word Tracking.")
        case (false, true):
            return L10n.text("Use Grant Access to enable the microphone for Word Tracking.")
        case (true, false):
            return L10n.text("Use Grant Access to enable Speech Recognition for Word Tracking.")
        case (false, false):
            return L10n.text("Use Grant Access to enable Microphone and Speech Recognition for Word Tracking.")
        }
    }

    private var teleprompterPermissionButtonTitle: String {
        let microphone = permissions.snapshot?.microphone ?? .notDetermined
        let speech = permissions.snapshot?.speech ?? .notDetermined
        if microphone == .denied || microphone == .restricted ||
            speech == .denied || speech == .restricted {
            return L10n.text("Open Settings")
        }
        return L10n.text("Grant Access")
    }

    private func requestTeleprompterPermissions() {
        SettingsWindowController.shared.beginPermissionRequest()
        Task { await permissions.requestWordTrackingAccess() }
    }

}
