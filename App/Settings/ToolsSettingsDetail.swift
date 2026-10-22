import SwiftUI

struct ToolsSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var manager = ToolsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingSectionLabel(title: "Keep Awake")
            SettingGroup {
                SettingPickerRow(title: "Default Duration",
                    description: "Used the next time you turn on Keep Awake.",
                    selection: $appState.keepAwakeDuration, identifier: "tools-default-duration") {
                    ForEach(KeepAwakeDuration.allCases) { option in Text(option.title).tag(option) }
                }
                if appState.keepAwakeDuration == .custom {
                    SettingRowDivider()
                    SettingNumberRow(title: "Custom Duration", description: "From 1 minute to 24 hours.",
                        value: $appState.keepAwakeCustomMinutes, step: 1, range: 1...1440, unit: "minutes",
                        identifier: "tools-custom-minutes")
                }
                SettingRowDivider()
                SettingNote("The display and Mac stay awake until time runs out or you turn it off. Manual sleep and lid closure still work.")
                if let error = manager.awakeError, manager.isKeepingAwake {
                    SettingRowDivider()
                    SettingContent {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Spacer()
                            Button("Retry") { appState.setModuleEnabled(.tools, enabled: false) }
                                .accessibilityIdentifier("tools-stop-retry")
                        }
                    }
                }
            }

            SettingSectionLabel(title: "Keyboard Cleaning").padding(.top, 8)
            SettingGroup {
                SettingPermissionRow(title: "Accessibility", description: "Required to lock keyboard input.",
                    isGranted: manager.hasKeyboardAccess) {
                    Button(L10n.text("Allow Accessibility")) {
                        SettingsWindowController.shared.beginPermissionRequest()
                        PermissionsManager.shared.requestAccessibility()
                        PermissionsManager.shared.openAccessibilitySettings()
                    }.accessibilityIdentifier("tools-accessibility")
                }
                SettingRowDivider()
                SettingActionRow(title: "Clean your keyboard",
                    description: "No time limit. Use the mouse to click End Cleaning when done.",
                    buttonTitle: "Open Tools", identifier: "tools-settings-open") {
                    appState.presentFullExpandedModule(.tools)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tools-settings-content")
    }
}
