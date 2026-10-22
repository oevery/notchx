import Foundation

enum IslandIdleContent: String, CaseIterable, Identifiable {
    case battery, weather, calendar, none
    var id: String { rawValue }
    var module: ModuleType? {
        switch self {
        case .battery: return .battery
        case .weather: return .weather
        case .calendar: return .calendar
        case .none: return nil
        }
    }
    var title: String { module?.displayName ?? L10n.text("Empty") }
}

enum IslandEventKind: String, CaseIterable, Identifiable {
    case volume, powerChanged, lowBattery, batteryFull, bluetoothConnected, bluetoothDisconnected, calendarReminder, notification
    var id: String { rawValue }
    var module: ModuleType {
        switch self {
        case .volume: return .volumeHUD
        case .powerChanged, .lowBattery, .batteryFull: return .battery
        case .bluetoothConnected, .bluetoothDisconnected: return .connectivity
        case .calendarReminder: return .calendar
        case .notification: return .notifications
        }
    }
    var title: String {
        switch self {
        case .volume: return L10n.text("Volume changes")
        case .powerChanged: return L10n.text("Power and charging changes")
        case .lowBattery: return L10n.text("Low battery")
        case .batteryFull: return L10n.text("Fully charged")
        case .bluetoothConnected: return L10n.text("Device connected")
        case .bluetoothDisconnected: return L10n.text("Device disconnected")
        case .calendarReminder: return L10n.text("Calendar reminders")
        case .notification: return L10n.text("Incoming notifications")
        }
    }
    var defaultDuration: Double {
        switch self {
        case .volume: return 2.5
        case .calendarReminder: return 8
        case .notification: return 4
        default: return 2.5
        }
    }
    /// UI convenience only; the persisted/input duration range remains 1...30 seconds.
    var commonDurationRange: ClosedRange<Double> {
        switch self {
        case .lowBattery, .notification: return 1...10
        case .calendarReminder: return 1...15
        default: return 1...5
        }
    }
    var remembersWhileBusy: Bool { self == .calendarReminder || self == .notification || self == .lowBattery }
    var enabledKey: String { "island.event." + rawValue + ".enabled" }
    var durationKey: String { "island.event." + rawValue + ".duration" }
}

struct IslandEventRule: Equatable {
    var enabled = true
    var duration: Double
}

struct IslandPresentationPreferences: Equatable {
    static let idleKey = "island.idleContent"
    static let thresholdKey = "battery.lowThreshold"
    static let ignoredDevicesKey = "connectivity.ignoredDeviceIDs"
    var idleContent: IslandIdleContent = .battery
    var lowBatteryThreshold = 20
    var ignoredBluetoothDeviceIDs: Set<String> = []
    var rules = Dictionary(uniqueKeysWithValues: IslandEventKind.allCases.map { ($0, IslandEventRule(duration: $0.defaultDuration)) })

    subscript(_ kind: IslandEventKind) -> IslandEventRule {
        get { rules[kind] ?? IslandEventRule(duration: kind.defaultDuration) }
        set { rules[kind] = IslandEventRule(enabled: newValue.enabled, duration: Self.duration(newValue.duration, fallback: kind.defaultDuration)) }
    }
    static func duration(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(30, max(1, value)) : fallback }
    static func load(from defaults: UserDefaults) -> Self {
        var result = Self()
        result.idleContent = IslandIdleContent(rawValue: defaults.string(forKey: idleKey) ?? "") ?? .battery
        result.lowBatteryThreshold = min(50, max(5, (defaults.object(forKey: thresholdKey) as? Int) ?? 20))
        result.ignoredBluetoothDeviceIDs = Set(defaults.stringArray(forKey: ignoredDevicesKey) ?? [])
        for kind in IslandEventKind.allCases {
            result[kind] = IslandEventRule(enabled: defaults.object(forKey: kind.enabledKey) as? Bool ?? true,
                                          duration: defaults.object(forKey: kind.durationKey) as? Double ?? kind.defaultDuration)
        }
        return result
    }
    func saveChanges(from previous: Self, to defaults: UserDefaults) {
        if idleContent != previous.idleContent { defaults.set(idleContent.rawValue, forKey: Self.idleKey) }
        if lowBatteryThreshold != previous.lowBatteryThreshold { defaults.set(min(50, max(5, lowBatteryThreshold)), forKey: Self.thresholdKey) }
        if ignoredBluetoothDeviceIDs != previous.ignoredBluetoothDeviceIDs { defaults.set(ignoredBluetoothDeviceIDs.sorted(), forKey: Self.ignoredDevicesKey) }
        for kind in IslandEventKind.allCases {
            if self[kind].enabled != previous[kind].enabled { defaults.set(self[kind].enabled, forKey: kind.enabledKey) }
            if self[kind].duration != previous[kind].duration { defaults.set(Self.duration(self[kind].duration, fallback: kind.defaultDuration), forKey: kind.durationKey) }
        }
    }
    static func restoreEntries(for module: ModuleType) -> [SettingsRestoreEntry] {
        var entries = IslandEventKind.allCases.filter { $0.module == module }.flatMap {
            [SettingsRestoreEntry(key: $0.enabledKey, value: true), SettingsRestoreEntry(key: $0.durationKey, value: $0.defaultDuration)]
        }
        if module == .battery { entries.append(SettingsRestoreEntry(key: thresholdKey, value: 20)) }
        if module == .connectivity { entries.append(SettingsRestoreEntry(key: ignoredDevicesKey, value: nil)) }
        return entries
    }
}
