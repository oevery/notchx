import SwiftUI

struct ToolsView: View {
    private enum DurationTrigger { case menu, minutes }

    @ObservedObject var manager = ToolsManager.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.basicControlSize) private var controlSize
    @State private var durationEdit: KeepAwakeDurationDraft?
    @State private var durationTrigger: DurationTrigger = .menu
    @State private var menuFocusRequest: UUID?
    @State private var restoreMinutesFocus = false
    @FocusState private var minutesTriggerFocused: Bool

    var body: some View {
        Group {
            if manager.cleaningState.isBlocking { cleaningContent }
            else { toolsContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .islandTransientInteraction(isPresented: Binding(get: { durationEdit != nil },
            set: { if !$0 { discardDurationEdit() } }), module: .tools)
        .onChange(of: manager.cleaningState) { _, state in
            if state.isBlocking { discardDurationEdit() }
        }
        .onChange(of: manager.isKeepingAwake) { _, active in if active { discardDurationEdit() } }
        .onChange(of: appState.keepAwakeCustomMinutes) { _, _ in discardDurationEdit() }
        .onChange(of: appState.keepAwakeDuration) { _, _ in discardDurationEdit() }
        .onKeyPress(.escape) {
            guard durationEdit != nil else { return .ignored }
            finishDurationEdit(save: false)
            return .handled
        }
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                toolIcon("cup.and.saucer.fill", color: .orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep Awake").font(IslandTypography.heading).foregroundStyle(IslandPalette.primary)
                        .accessibilityIdentifier("tools-awake-title")
                    HStack(spacing: 8) {
                        if manager.isKeepingAwake {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(manager.awakeRemainingDescription)
                                    .font(IslandTypography.time).foregroundStyle(IslandPalette.secondary)
                            }
                        } else {
                            durationControls
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 8) { awakeActions }.fixedSize()
                    }
                    .frame(minHeight: controlSize.islandHeight)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let error = manager.awakeError { errorText(error) }
            IslandDivider()
            HStack(spacing: 12) {
                toolIcon("keyboard", color: .cyan)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keyboard Cleaning").font(IslandTypography.heading).foregroundStyle(IslandPalette.primary)
                        .accessibilityIdentifier("tools-cleaning-title")
                    Text("Lock the keyboard until you click End Cleaning.")
                        .font(IslandTypography.secondary).foregroundStyle(IslandPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                Group {
                    if manager.hasKeyboardAccess {
                        Button(L10n.text("Start Cleaning")) { manager.startCleaning() }
                            .accessibilityIdentifier("keyboard-cleaning-start")
                    } else {
                        Button(L10n.text("Allow Accessibility")) {
                            appState.performExternalAction(for: .tools) {
                                PermissionsManager.shared.requestAccessibility()
                                PermissionsManager.shared.openAccessibilitySettings()
                                return true
                            }
                        }
                        .accessibilityIdentifier("keyboard-cleaning-permission")
                    }
                }
                .buttonStyle(IslandButtonStyle(.secondary))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 48, alignment: .trailing)
            }
            if let error = manager.cleaningError { errorText(error) }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tools-content")
    }

    @ViewBuilder
    private var durationControls: some View {
        let options = KeepAwakeDuration.allCases
        IslandMenuButton(label: L10n.text("Duration"), identifier: "keep-awake-duration", module: .tools,
            items: options.map { option in
                IslandMenuItem(title: option.title) { selectDuration(option) }
            }, selectedIndex: options.firstIndex(of: appState.keepAwakeDuration) ?? 0, focusRequest: menuFocusRequest)
            .islandInputChrome(insetsContent: false)
            .fixedSize()
            .disabled(durationEdit != nil)
        if durationEdit != nil {
            customDurationEditor
        } else if appState.keepAwakeDuration == .custom {
            Button(L10n.format("%d min", Int(appState.keepAwakeCustomMinutes))) { beginDurationEdit(from: .minutes) }
                .buttonStyle(IslandButtonStyle(.secondary))
                .fixedSize()
                .help(L10n.text("Edit Custom Duration"))
                .accessibilityIdentifier("keep-awake-edit-custom")
                .focused($minutesTriggerFocused)
                .task {
                    if restoreMinutesFocus {
                        restoreMinutesFocus = false
                        minutesTriggerFocused = true
                    }
                }
        }
    }

    @ViewBuilder
    private var awakeActions: some View {
        if manager.isKeepingAwake {
            Button(L10n.text("Turn Off")) { manager.stopKeepingAwake() }
                .buttonStyle(IslandButtonStyle(.secondary))
                .accessibilityIdentifier("keep-awake-stop")
        } else if durationEdit != nil {
            Button(L10n.text("Cancel")) { finishDurationEdit(save: false) }
                .buttonStyle(IslandButtonStyle(.secondary))
                .accessibilityIdentifier("keep-awake-custom-cancel")
            Button(L10n.text("Done")) { finishDurationEdit(save: true) }
                .buttonStyle(IslandButtonStyle(.primary))
                .accessibilityIdentifier("keep-awake-custom-done")
        } else {
            Button(L10n.text("Turn On")) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                manager.startKeepingAwake(for: appState.keepAwakeDuration)
            }
            .buttonStyle(IslandButtonStyle(.primary))
            .accessibilityIdentifier("keep-awake-start")
        }
    }

    private var customDurationEditor: some View {
        HStack(spacing: 6) {
            SettingNumericTextField(title: L10n.text("Custom Duration"),
                text: Binding(get: { durationEdit?.text ?? "" }, set: { durationEdit?.text = $0 }),
                identifier: "keep-awake-custom-minutes", onCommit: {}, focusOnMount: true,
                onSubmit: { finishDurationEdit(save: true) }, onCancel: { finishDurationEdit(save: false) },
                usesIslandChrome: true)
                .frame(width: 52)
                .islandInputChrome()
                .help(L10n.text("1–1440 minutes"))
                .accessibilityHint(L10n.text("1–1440 minutes"))
            Text("minutes").font(IslandTypography.secondary).foregroundStyle(IslandPalette.secondary)
            Stepper(L10n.text("Custom Duration"), value: Binding(
                get: { durationEdit?.minutes(in: locale) ?? appState.keepAwakeCustomMinutes },
                set: { durationEdit?.setMinutes($0, locale: locale) }), in: KeepAwakeDuration.customMinutesRange, step: 1)
                .labelsHidden()
                .accessibilityIdentifier("keep-awake-custom-stepper")
        }
        .fixedSize()
    }

    private func selectDuration(_ duration: KeepAwakeDuration) {
        if duration == .custom { beginDurationEdit(from: .menu) }
        else { appState.keepAwakeDuration = duration }
    }

    private func beginDurationEdit(from trigger: DurationTrigger) {
        guard durationEdit == nil, !manager.isKeepingAwake, !manager.cleaningState.isBlocking else { return }
        durationTrigger = trigger
        durationEdit = KeepAwakeDurationDraft(minutes: appState.keepAwakeCustomMinutes, locale: locale)
    }

    private func finishDurationEdit(save: Bool) {
        guard let durationEdit else { return }
        if save {
            durationEdit.confirm(in: appState, locale: locale)
        }
        self.durationEdit = nil
        switch durationTrigger {
        case .menu: menuFocusRequest = UUID()
        case .minutes: restoreMinutesFocus = true
        }
    }

    private func discardDurationEdit() {
        if durationEdit != nil {
            durationEdit = nil
            restoreMinutesFocus = false
        }
    }

    private func toolIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color)
            .frame(width: 28, height: 48)
    }

    private var cleaningContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 28)).foregroundStyle(.cyan)
            Text("Keyboard Locked").font(.headline).foregroundStyle(IslandPalette.primary)
            Text(manager.cleaningState == .releasing
                 ? L10n.text("Release all keys to finish cleaning.")
                 : L10n.text("Clean your keyboard. Click below when you are done."))
                .font(.callout).foregroundStyle(IslandPalette.secondary).multilineTextAlignment(.center)
            Button(L10n.text("End Cleaning")) { manager.endCleaning() }
                .buttonStyle(IslandButtonStyle(.primary))
                .disabled(manager.cleaningState == .releasing)
                .accessibilityIdentifier("keyboard-cleaning-end")
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-cleaning-locked")
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct KeepAwakeDurationDraft {
    let originalMinutes: Double
    var text: String

    init(minutes: Double, locale: Locale) {
        originalMinutes = minutes
        text = minutes.formatted(.number.locale(locale))
    }

    func minutes(in locale: Locale) -> Double {
        KeepAwakeDuration.boundedCustomMinutes(SettingValueBounds.committedValue(from: text,
            currentValue: originalMinutes, in: KeepAwakeDuration.customMinutesRange, locale: locale))
    }

    mutating func setMinutes(_ minutes: Double, locale: Locale) {
        text = KeepAwakeDuration.boundedCustomMinutes(minutes).formatted(.number.locale(locale))
    }

    @MainActor
    func confirm(in appState: AppState, locale: Locale) {
        appState.keepAwakeCustomMinutes = minutes(in: locale)
        appState.keepAwakeDuration = .custom
    }
}

struct ToolsExpandedView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        Button { appState.presentFullExpandedModule(.tools) } label: {
            Label(L10n.text("Open Tools"), systemImage: "wrench.and.screwdriver")
        }
        .buttonStyle(IslandButtonStyle(.secondary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToolsCompactView: View {
    var body: some View {
        HStack(spacing: 8) {
            KeepAwakeCompactIcon()
            Spacer(minLength: 0)
            KeepAwakeCompactCountdown()
        }
    }
}

struct KeepAwakeCompactIcon: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        Button { appState.presentFullExpandedModule(.tools) } label: {
            CompactSlot(kind: .indicator) { _ in
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain).help(L10n.text("Open Tools"))
        .accessibilityLabel(L10n.text("Keep Awake"))
    }
}

struct KeepAwakeCompactCountdown: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var manager = ToolsManager.shared
    var body: some View {
        Group {
            if manager.isAwakeIndefinite { countdownButton(remaining: nil) }
            else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in countdownButton(remaining: manager.awakeRemaining) }
            }
        }
    }

    private func countdownButton(remaining: TimeInterval?) -> some View {
        Button { appState.presentFullExpandedModule(.tools) } label: {
            KeepAwakeCountdownLabel(remaining: remaining)
        }
        .buttonStyle(.plain).help(L10n.text("Open Tools"))
    }
}

/// At most five characters; longer sessions omit seconds and indefinite sessions use a symbol.
struct KeepAwakeCountdownLabel: View {
    let remaining: TimeInterval?
    var body: some View {
        Group {
            if let remaining {
                Text(ToolsManager.countdownText(remaining))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityLabel(remaining >= 3600
                        ? L10n.format("%dh %dm remaining", Int(ceil(remaining / 60)) / 60, Int(ceil(remaining / 60)) % 60)
                        : L10n.format("%@ remaining", ToolsManager.countdownText(remaining)))
            } else {
                Image(systemName: "infinity").font(.system(size: 15, weight: .medium))
                    .accessibilityLabel(L10n.text("Forever"))
            }
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
