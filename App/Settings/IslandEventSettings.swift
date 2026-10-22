import SwiftUI
import AppKit

struct IslandEventSettings: View {
    @EnvironmentObject private var appState: AppState
    let module: ModuleType
    var reminderLeadTime: Binding<Int>? = nil

    private var events: [IslandEventKind] { IslandEventKind.allCases.filter { $0.module == module } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingSectionLabel(title: "Automatic display")
            SettingGroup {
                ForEach(events) { event in
                    SettingToggleRow(title: event.title, isOn: Binding(
                        get: { appState.presentationPreferences[event].enabled },
                        set: { appState.presentationPreferences[event].enabled = $0 }),
                        identifier: "event-enabled-" + event.rawValue)
                    if appState.presentationPreferences[event].enabled {
                        if event == .calendarReminder, let leadTime = reminderLeadTime {
                            SettingNumberRow(title: "Reminder lead time", value: .settingInteger(leadTime),
                                             step: 1, range: 1...60, unit: "min", identifier: "settings-calendar-lead-time")
                        }
                        SettingSliderNumberRow(title: "Display duration", value: Binding(
                            get: { appState.presentationPreferences[event].duration },
                            set: { appState.presentationPreferences[event].duration = $0 }),
                            range: 1...30, commonRange: event.commonDurationRange, unit: "s", identifier: "event-duration-" + event.rawValue)
                        if event == .lowBattery {
                            SettingNumberRow(title: "Low battery threshold",
                                value: .settingInteger($appState.presentationPreferences.lowBatteryThreshold),
                                step: 5, range: 5...50, unit: "%")
                        }
                    }
                    if event != events.last { SettingRowDivider() }
                }
            }
        }
    }
}

struct PendingIslandEventsMenu: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        if !appState.pendingIslandEvents.isEmpty {
            Menu {
                ForEach(appState.pendingIslandEvents) { event in
                    Button(event.title) { appState.viewPendingEvent(event) }
                }
            } label: { Image(systemName: "bell.badge.fill").foregroundStyle(.orange) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(Text("Pending island events"))
            .help("View reminders without interrupting the current activity")
        }
    }
}

struct VolumeSettingsDetail: View {
    var body: some View {
        IslandEventSettings(module: .volumeHUD)
    }
}

struct BatterySettingsDetail: View {
    var body: some View {
        IslandEventSettings(module: .battery)
    }
}

struct ConnectivitySettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = BluetoothManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IslandEventSettings(module: .connectivity)
            SettingGroup {
                SettingDisclosureGroup(title: "Device alert exclusions") {
                    if manager.knownDevices.isEmpty {
                        SettingNote("Paired devices appear here when available.")
                    }
                    ForEach(manager.knownDevices) { device in
                        SettingToggleRow(title: device.name, isOn: Binding(
                        get: { appState.presentationPreferences.ignoredBluetoothDeviceIDs.contains(device.id) },
                        set: { ignored in
                            if ignored { appState.presentationPreferences.ignoredBluetoothDeviceIDs.insert(device.id) }
                            else { appState.presentationPreferences.ignoredBluetoothDeviceIDs.remove(device.id) }
                        }))
                    }
                    SettingNote("Ignore connection alerts for selected devices. Battery information is shown only when available.")
                }
            }
        }
    }
}
