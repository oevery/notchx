import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        AppearanceSettingsContent(appState: appState)
            .id(ObjectIdentifier(appState))
    }
}

/// Controls, numeric edits and undo history share one AppState lifetime.
private struct AppearanceSettingsContent: View {
    @ObservedObject var appState: AppState
    @State private var dimensionResetGeneration = 0

    @StateObject private var restoreSession: SettingsRestoreSession

    init(appState: AppState) {
        self.appState = appState
        _restoreSession = StateObject(wrappedValue: SettingsRestoreSession(appState: appState))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            section(title: "Animation", scope: .animation) {
                SettingPickerRow(title: "Animation intensity", selection: $appState.manualMotionLevel, identifier: "settings-motion-level") {
                    ForEach(AnimationLevel.allCases) { level in Text(L10n.text(level.title)).tag(level) }
                }
                SettingNote("System accessibility and Low Power mode may further reduce motion.")
                SettingRowDivider()
                SettingDisclosureGroup(title: "Advanced animation settings") {
                    SettingNumberRow(title: "Bounce", description: "Spring bounce for compact ↔ expanded transitions",
                        value: Binding(get: { appState.bounceAmount * 100 }, set: { appState.bounceAmount = $0 / 100 }),
                        step: 5, range: 0...50, unit: "%", resetGeneration: dimensionResetGeneration)
                }
            }
            SettingGroup {
                SettingDisclosureGroup(title: "Animation timing") {
                    SettingNumberRow(title: "Animation Speed", value: $appState.animationSpeed, step: 0.1, range: 0.5...2, unit: "×")
                }
            }

            section(title: "Compact Island Size", scope: .compactSize) {
                sizeRow(
                    title: "Width",
                    description: "Pill width on notched Macs",
                    value: $appState.compactIslandWidth,
                    range: 140...320,
                    unit: "pt"
                )
                SettingRowDivider()
                sizeRow(
                    title: "Height",
                    description: "Pill height on notched Macs",
                    value: $appState.compactIslandHeight,
                    range: 28...60,
                    unit: "pt"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: appState.animationLevelRaw) { _, _ in restoreSession.discardUndoIfChanged(.animation) }
        .onChange(of: appState.reduceMotion) { _, _ in restoreSession.discardUndoIfChanged(.animation) }
        .onChange(of: appState.reduceAnimations) { _, _ in restoreSession.discardUndoIfChanged(.animation) }
        .onChange(of: appState.bounceAmount) { _, _ in restoreSession.discardUndoIfChanged(.animation) }
        .onChange(of: appState.compactIslandWidth) { _, _ in restoreSession.discardUndoIfChanged(.compactSize) }
        .onChange(of: appState.compactIslandHeight) { _, _ in restoreSession.discardUndoIfChanged(.compactSize) }
        .environmentObject(appState)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        scope: SettingsRestoreScope,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingSectionLabel(title: title)
        SettingGroup {
            content()
            SettingRowDivider()
            SettingRestoreRow(description: scope.description, buttonTitle: "Restore Group Defaults",
                undo: restoreSession.canUndo(scope) ? {
                    dimensionResetGeneration += 1
                    restoreSession.undo(scope)
                } : nil) {
                    dimensionResetGeneration += 1
                    restoreSession.restoreGroup(scope)
                }
        }
    }

    private func sizeRow(
        title: String,
        description: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        SettingSliderNumberRow(title: title, description: description, value: value,
                               range: range, unit: unit, resetGeneration: dimensionResetGeneration)
    }
}
