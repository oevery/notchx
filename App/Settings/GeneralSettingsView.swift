import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var launchAtLogin = LaunchAtLoginState.shared
    @ObservedObject private var permissions = PermissionState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Language")
            SettingGroup {
                SettingRow(title: "Language") {
                    SettingChoiceField {
                        LanguagePicker().pickerStyle(.menu).accessibilityLabel(L10n.text("Language"))
                    }
                }
            }

            SettingSectionLabel(title: "Startup")
            SettingGroup {
                SettingToggleRow(title: "Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }))
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                SettingRowDivider()
                SettingToggleRow(title: "Show menu bar icon", isOn: $appState.showMenuBarIcon)
            }

            // Display
            SettingSectionLabel(title: "Display")
            SettingGroup {
                SettingToggleRow(
                    title: "Show in screenshots and screen recordings",
                    description: "Turn off to exclude the island from supported captures. Some capture apps may ignore this setting.",
                    isOn: $appState.showInScreenRecordings
                )
                SettingRowDivider()
                SettingToggleRow(title: "Show on all Spaces", isOn: $appState.showOnAllSpaces)
                if appState.presentationHasNotch {
                    SettingRowDivider()
                    SettingToggleRow(title: "Hide side slots", isOn: $appState.hideSideSlots)
                }
                SettingRowDivider()
                SettingToggleRow(title: "Hide on fullscreen", isOn: $appState.hideOnFullscreen)
            }

            // Power
            SettingSectionLabel(title: "Power")
            SettingGroup {
                SettingPickerRow(title: "Power mode", description: appState.energyMode.description, selection: energyModeBinding) {
                    ForEach(EnergyMode.allCases) { mode in
                        Text(L10n.text(mode.title)).tag(mode)
                    }
                }

                SettingRowDivider()
                SettingToggleRow(
                    title: "Low Power suggestions",
                    description: "Offer Low Power mode when the Mac switches to battery or refresh work stays busy.",
                    isOn: lowPowerSuggestionBinding
                )
            }


            // Behavior
            SettingSectionLabel(title: "Behavior")
            SettingGroup {
                SettingPickerRow(title: "Idle island content", selection: $appState.presentationPreferences.idleContent) {
                    ForEach(IslandIdleContent.allCases) { item in Text(L10n.text(item.title)).tag(item) }
                }
                SettingNote("Used when no activity is running. A disabled module leaves the island empty.")
                SettingNote("Turning off automatic events keeps the module available in Home and its detail page. Busy activities are not interrupted.")
                SettingRowDivider()
                SettingSliderNumberRow(title: "Expanded collapse delay", description: "How long expanded content stays visible",
                    value: $appState.expandedAutoDismissDelay, range: 0.1...10, commonRange: 0.1...3, unit: "s", identifier: "settings-collapse-delay")
                SettingRowDivider()
                SettingSliderNumberRow(title: "Hover expand delay", description: "How long to hover the notch before it peeks open",
                    value: $appState.hoverExpandDelay, range: 0...1.5, commonRange: 0...1, unit: "s", identifier: "settings-hover-delay")
            }

            // Interaction
            SettingSectionLabel(title: "Interaction")
            SettingGroup {
                SettingToggleRow(title: "Island surface swipes", isOn: $appState.islandSurfaceSwipeEnabled)
                SettingRowDivider()
                SettingPickerRow(title: "Notch haptic intensity", description: "Feedback strength when entering the notch",
                                 selection: $appState.notchHapticIntensity) {
                    ForEach(NotchHapticIntensity.allCases) { intensity in
                        Text(L10n.text(intensity.title)).tag(intensity.rawValue)
                    }
                }

                SettingRowDivider()
                SettingToggleRow(
                    title: "Allow Command+Q to quit",
                    description: "Turn this off to prevent accidental quits while interacting with the notch.",
                    isOn: $appState.allowQuitHotkey
                )
            }

            // Permissions
            SettingSectionLabel(title: "Permissions")
            SettingGroup {
                if AppCodeSigning.hasUnstableIdentity {
                    SettingContent {
                        SettingSupportingText("This build uses an ad-hoc or unsigned identity. macOS may require permission again after rebuilding. Configure a development signing certificate to keep the app identity stable.")
                    }
                    SettingRowDivider()
                }
                permissionRow(.accessibility,
                    title: "Accessibility",
                    description: "Gesture detection and system events")
                SettingRowDivider()
                permissionRow(.calendar,
                    title: "Calendar",
                    description: "Show upcoming events in the island")
                SettingRowDivider()
                permissionRow(.location,
                    title: "Location",
                    description: "Weather information for your location")
                SettingRowDivider()
                permissionRow(.bluetooth,
                    title: "Bluetooth",
                    description: "Connected device notifications")
            }


        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { launchAtLogin.refresh() }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
            Task { await permissions.refresh() }
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ permission: PermissionType,
        title: String, description: String
    ) -> some View {
        SettingPermissionRow(title: title, description: description, isGranted: permissionGranted(permission)) {
            Button("Grant Access") { requestPermission(permission) }
        }
    }

    private func permissionGranted(_ permission: PermissionType) -> Bool {
        permissions.snapshot?.granted.contains(permission) == true
    }

    private var energyModeBinding: Binding<EnergyMode> {
        Binding(
            get: { appState.energyMode },
            set: { appState.energyMode = $0 }
        )
    }

    private var lowPowerSuggestionBinding: Binding<Bool> {
        Binding(
            get: { !appState.lowPowerSuggestionDoNotAskAgain },
            set: { appState.lowPowerSuggestionDoNotAskAgain = !$0 }
        )
    }

    private func requestPermission(_ permission: PermissionType) {
        SettingsWindowController.shared.beginPermissionRequest()
        Task { await permissions.request(permission) }
    }
}
