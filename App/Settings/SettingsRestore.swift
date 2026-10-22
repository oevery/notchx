import Foundation
import SwiftUI

/// The same keys and defaults are used at first launch and by scoped restores.
struct SettingDefault<Value: Sendable>: Sendable {
    let key: String
    let value: Value

    func read(from defaults: UserDefaults = .standard) -> Value {
        defaults.object(forKey: key) as? Value ?? value
    }

    fileprivate var entry: SettingsRestoreEntry { SettingsRestoreEntry(key: key, value: value) }
}

enum SettingsDefaults {
    enum Appearance {
        static let animationLevel = SettingDefault(key: "appearance.animationLevel", value: AnimationLevel.full.rawValue)
        static let reduceMotion = SettingDefault(key: "appearance.reduceMotion", value: false)
        static let reduceAnimations = SettingDefault(key: "energy.reduceAnimations", value: false)
        static let bounceAmount = SettingDefault(key: "appearance.bounceAmount", value: 0.25)
        static let compactWidth = SettingDefault(key: "appearance.compactIslandWidth", value: 200.0)
        static let compactHeight = SettingDefault(key: "appearance.compactIslandHeight", value: 36.0)
    }
    enum NowPlaying {
        static let compactMusic = SettingDefault(key: "nowPlaying.compactMusic", value: true)
        static let pauseRetention = SettingDefault(key: "nowPlaying.pauseRetention", value: 5)
        static let artworkGlow = SettingDefault(key: "nowPlaying.artworkGlow", value: true)
        static let browserDetection = SettingDefault(key: "nowPlaying.browserDetection.enabled", value: false)
        static let allowedBrowsers = SettingDefault(key: "nowPlaying.browserDetection.allowedBrowserBundleIDs", value: ["com.google.Chrome"])
    }
    enum Shelf {
        static let autoOpenOnDrop = SettingDefault(key: "module.shelf.autoOpenOnDrop", value: true)
        static let expandOnDragApproach = SettingDefault(key: "module.shelf.expandOnDragApproach", value: true)
    }
    enum Tools {
        static let awakeDuration = SettingDefault(key: "tools.keepAwake.duration", value: 1800)
        static let customMinutes = SettingDefault(key: "tools.keepAwake.customMinutes", value: 90.0)
    }
    enum Calendar {
        static let hideBirthdays = SettingDefault(key: "calendar.hideBirthdays", value: false)
        static let hideHolidays = SettingDefault(key: "calendar.hideHolidays", value: false)
        static let collapseDuplicates = SettingDefault(key: "calendar.collapseDuplicates", value: true)
        static let lookaheadDays = SettingDefault(key: "calendar.lookaheadDays", value: 7)
        static let preEventMinutes = SettingDefault(key: "calendar.preEventMinutes", value: 10)
        // Absence represents all calendars, including calendars added later.
        static let enabledCalendarIDsKey = "calendar.enabledCalendarIDs"
    }
    enum Weather {
        static let temperatureUnit = SettingDefault(key: "module.weather.temperatureUnit", value: TemperatureUnit.celsius.rawValue)
        static let windUnit = SettingDefault(key: "weather.windUnit", value: WeatherWindUnit.automatic.rawValue)
    }
    enum Notifications {
        static let showPreviews = SettingDefault(key: "module.notifications.showPreviews", value: true)
        static let enabledSources = SettingDefault(key: "module.notifications.enabledSources", value: NotificationFeedSource.defaultEnabledRawValue)
        static let mutedAppsKey = "notifications.mutedApps"
        static let pausedUntilKey = "notifications.pausedUntil"
    }
    enum Teleprompter {
        static let listeningMode = SettingDefault(key: "teleprompter.listeningMode", value: TeleprompterListeningMode.classic.rawValue)
        static let scrollSpeed = SettingDefault(key: "teleprompter.scrollSpeed", value: 7.0)
        static let fontSize = SettingDefault(key: "teleprompter.fontSize", value: 22.0)
        static let alignment = SettingDefault(key: "teleprompter.alignment", value: 1)
        static let columnWidth = SettingDefault(key: "teleprompter.columnWidth", value: 1.0)
        static let readingGuide = SettingDefault(key: "teleprompter.readingGuide", value: false)
        static let countdown = SettingDefault(key: "teleprompter.countdownSeconds", value: 3)
        static let guidePosition = SettingDefault(key: "teleprompter.guidePosition", value: 0.35)
        static let globalShortcuts = SettingDefault(key: "teleprompter.globalShortcuts", value: false)
        static let shortcutModifiers = SettingDefault(key: "teleprompter.shortcutModifiers", value: "controlOption")
        // Absence resolves through the manager's supported system-language fallback.
        static let speechLocaleKey = "teleprompter.speechLocale"
    }
}

struct SettingsRestoreEntry {
    let key: String
    let value: Any?
}

enum SettingsRestoreScope: Hashable {
    case animation, compactSize, moduleOrder
    case module(ModuleType)

    var entries: [SettingsRestoreEntry] {
        let eventEntries: [SettingsRestoreEntry]
        if case .module(let module) = self { eventEntries = IslandPresentationPreferences.restoreEntries(for: module) }
        else { eventEntries = [] }
        return baseEntries + eventEntries
    }

    private var baseEntries: [SettingsRestoreEntry] {
        switch self {
        case .moduleOrder: return [SettingsRestoreEntry(key: ModuleOrder.key, value: "")]
        case .animation:
            return [SettingsDefaults.Appearance.animationLevel.entry, SettingsDefaults.Appearance.reduceMotion.entry,
                    SettingsDefaults.Appearance.reduceAnimations.entry, SettingsDefaults.Appearance.bounceAmount.entry]
        case .compactSize:
            return [SettingsDefaults.Appearance.compactWidth.entry, SettingsDefaults.Appearance.compactHeight.entry]
        case .module(.nowPlaying):
            return [SettingsDefaults.NowPlaying.compactMusic.entry, SettingsDefaults.NowPlaying.pauseRetention.entry,
                    SettingsDefaults.NowPlaying.artworkGlow.entry, SettingsDefaults.NowPlaying.browserDetection.entry,
                    SettingsDefaults.NowPlaying.allowedBrowsers.entry]
        case .module(.shelf):
            // Retention can delete files. Restore only the drop behavior.
            return [SettingsDefaults.Shelf.autoOpenOnDrop.entry, SettingsDefaults.Shelf.expandOnDragApproach.entry]
        case .module(.calendar):
            return [SettingsDefaults.Calendar.hideBirthdays.entry, SettingsDefaults.Calendar.hideHolidays.entry,
                    SettingsDefaults.Calendar.collapseDuplicates.entry, SettingsDefaults.Calendar.lookaheadDays.entry,
                    SettingsDefaults.Calendar.preEventMinutes.entry,
                    SettingsRestoreEntry(key: SettingsDefaults.Calendar.enabledCalendarIDsKey, value: nil)]
        case .module(.weather):
            return [SettingsDefaults.Weather.temperatureUnit.entry, SettingsDefaults.Weather.windUnit.entry]
        case .module(.notifications):
            // Do not reduce retention or re-filter existing notification history.
            return [SettingsDefaults.Notifications.showPreviews.entry, SettingsDefaults.Notifications.enabledSources.entry,
                    SettingsRestoreEntry(key: SettingsDefaults.Notifications.mutedAppsKey, value: nil), SettingsRestoreEntry(key: SettingsDefaults.Notifications.pausedUntilKey, value: nil)]
        case .module(.teleprompter):
            return [SettingsDefaults.Teleprompter.listeningMode.entry, SettingsDefaults.Teleprompter.scrollSpeed.entry,
                    SettingsDefaults.Teleprompter.fontSize.entry, SettingsDefaults.Teleprompter.alignment.entry,
                    SettingsDefaults.Teleprompter.columnWidth.entry, SettingsDefaults.Teleprompter.readingGuide.entry,
                    SettingsDefaults.Teleprompter.countdown.entry,
                    SettingsDefaults.Teleprompter.guidePosition.entry, SettingsDefaults.Teleprompter.globalShortcuts.entry,
                    SettingsDefaults.Teleprompter.shortcutModifiers.entry,
                    SettingsRestoreEntry(key: SettingsDefaults.Teleprompter.speechLocaleKey, value: nil)]
        case .module(.tools):
            return [SettingsDefaults.Tools.awakeDuration.entry, SettingsDefaults.Tools.customMinutes.entry]
        case .module(.volumeHUD), .module(.battery), .module(.connectivity), .module(.agent):
            return []
        }
    }

    var description: String {
        switch self {
        case .moduleOrder: return L10n.text("Restores module navigation order. Module settings and event priority are kept.")
        case .animation: return L10n.text("Restores motion and visual effects preferences and bounce. Animation speed is kept.")
        case .compactSize: return L10n.text("Restore compact island width and height.")
        case .module(.nowPlaying): return L10n.text("Restores music display, pause retention, artwork glow, and browser detection. macOS permissions are kept.")
        case .module(.shelf): return L10n.text("Restores drag and drop opening preferences. Shelf retention, files, and pinned items are kept.")
        case .module(.calendar): return L10n.text("Restores calendar filters, upcoming range, reminder timing, and all-calendar selection. Calendar access and events are kept.")
        case .module(.weather): return L10n.text("Restores temperature and wind units. Your selected city is kept.")
        case .module(.notifications): return L10n.text("Restores previews, sources, app filters, event display, and pause state. History, retained item limit, and system permissions are kept.")
        case .module(.teleprompter): return L10n.text("Restores reading, countdown, and speech preferences. Your script and macOS permissions are kept. Playback will pause.")
        case .module(.tools): return L10n.text("Restores the default wake duration and custom time. Active sessions and macOS permissions are kept.")
        case .module: return L10n.text("Restores this module's event display preferences. Module enablement and system permissions are kept.")
        }
    }

    @MainActor fileprivate func refreshRuntime(in appState: AppState?, from defaults: UserDefaults, domainName: String) {
        appState?.synchronizeRestoredPreferences(self, from: defaults, domainName: domainName)
        // Injected suites never refresh managers that read the owner's standard store.
        guard defaults === UserDefaults.standard else { return }
        switch self {
        case .module(.nowPlaying): NowPlayingManager.shared.reloadRestoredPreferences()
        case .module(.calendar): CalendarManager.shared.reloadRestoredPreferences()
        case .module(.teleprompter): TeleprompterManager.shared.reloadRestoredPreferences()
        case .module(.notifications): NotificationManager.shared.reloadDisplayPreferences()
        default: break
        }
    }
}

/// A settings-window transaction, deliberately limited to the allowlisted keys.
/// Module requests write nothing until confirmed; only the small groups offer Undo.
@MainActor
final class SettingsRestoreSession: ObservableObject {
    @Published private(set) var pendingModule: ModuleType?
    @Published private var undoSnapshots: [SettingsRestoreScope: [String: StoredValue]] = [:]
    private let defaults: UserDefaults
    private let domainName: String
    private let didRestore: (SettingsRestoreScope) -> Void
    private enum StoredValue { case absent, value(Any) }

    convenience init(appState: AppState) {
        self.init(defaults: appState.modulePreferenceStore,
                  domainName: appState.preferenceDomainName, appState: appState)
    }

    init(defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? "app.notchx",
         appState: AppState? = nil,
         didRestore: ((SettingsRestoreScope) -> Void)? = nil) {
        self.defaults = defaults
        self.domainName = domainName
        if let didRestore {
            self.didRestore = didRestore
        } else {
            let liveState = appState ?? (defaults === UserDefaults.standard ? AppState.shared : nil)
            self.didRestore = { $0.refreshRuntime(in: liveState, from: defaults, domainName: domainName) }
        }
    }

    func requestModuleRestore(_ module: ModuleType) {
        guard !SettingsRestoreScope.module(module).entries.isEmpty else {
            pendingModule = nil
            return
        }
        pendingModule = module
    }

    func cancelModuleRestore() { pendingModule = nil }

    func confirmModuleRestore() {
        guard let module = pendingModule else { return }
        pendingModule = nil
        restore(.module(module), keepingUndo: false)
    }

    func restoreGroup(_ scope: SettingsRestoreScope) {
        guard scope == .animation || scope == .compactSize || scope == .moduleOrder else { return }
        restore(scope, keepingUndo: true)
    }

    func canUndo(_ scope: SettingsRestoreScope) -> Bool {
        undoSnapshots[scope] != nil && isAtDefaults(scope)
    }

    func discardUndoIfChanged(_ scope: SettingsRestoreScope) {
        if !isAtDefaults(scope) { undoSnapshots.removeValue(forKey: scope) }
    }

    func undo(_ scope: SettingsRestoreScope) {
        guard canUndo(scope) else {
            undoSnapshots.removeValue(forKey: scope)
            return
        }
        guard let snapshot = undoSnapshots.removeValue(forKey: scope) else { return }
        for entry in scope.entries {
            switch snapshot[entry.key] ?? .absent {
            case .absent: defaults.removeObject(forKey: entry.key)
            case .value(let value): defaults.set(value, forKey: entry.key)
            }
        }
        didRestore(scope)
    }

    private func restore(_ scope: SettingsRestoreScope, keepingUndo: Bool) {
        guard !scope.entries.isEmpty else { return }
        // Repeated clicks at the default values keep the original Undo snapshot.
        if keepingUndo && !(undoSnapshots[scope] != nil && isAtDefaults(scope)) {
            let domain = defaults.persistentDomain(forName: domainName) ?? [:]
            undoSnapshots[scope] = Dictionary(uniqueKeysWithValues: scope.entries.map { entry in
                (entry.key, domain[entry.key].map { StoredValue.value($0) } ?? .absent)
            })
        }
        for entry in scope.entries {
            if let value = entry.value { defaults.set(value, forKey: entry.key) }
            else { defaults.removeObject(forKey: entry.key) }
        }
        didRestore(scope)
    }

    private func isAtDefaults(_ scope: SettingsRestoreScope) -> Bool {
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        return scope.entries.allSatisfy { entry in
            guard let expected = entry.value else { return domain[entry.key] == nil }
            guard let current = domain[entry.key] else { return false }
            return NSDictionary(dictionary: ["value": current]).isEqual(to: ["value": expected])
        }
    }
}
