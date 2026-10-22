import SwiftUI

struct ToolsView: View {
    @ObservedObject var manager = ToolsManager.shared
    @EnvironmentObject private var appState: AppState
    @State private var showsCustomDuration = false

    var body: some View {
        Group {
            if manager.cleaningState.isBlocking { cleaningContent }
            else { toolsContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .islandPopoverInteraction(isPresented: $showsCustomDuration, module: .tools)
        .onChange(of: manager.cleaningState) { _, state in
            if state.isBlocking { showsCustomDuration = false }
        }
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                toolIcon("cup.and.saucer.fill", color: .orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep Awake").font(.headline).accessibilityIdentifier("tools-awake-title")
                    if manager.isKeepingAwake {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(manager.awakeRemainingDescription)
                                .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            KeepAwakeDurationPicker(selection: Binding(get: { appState.keepAwakeDuration }, set: { selected in
                                appState.keepAwakeDuration = selected
                                if selected == .custom { showsCustomDuration = true }
                            }), holdsIslandPresentation: true)
                                .fixedSize(horizontal: true, vertical: false)
                            if appState.keepAwakeDuration == .custom {
                                Button(L10n.format("%d min", Int(appState.keepAwakeCustomMinutes))) { showsCustomDuration = true }
                                    .buttonStyle(.borderless).font(.caption)
                                    .help(L10n.text("Edit Custom Duration"))
                                    .accessibilityIdentifier("keep-awake-edit-custom")
                                    .popover(isPresented: $showsCustomDuration, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                                        customDurationEditor
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                Group {
                    if manager.isKeepingAwake {
                        Button(L10n.text("Turn Off")) { manager.stopKeepingAwake() }
                            .accessibilityIdentifier("keep-awake-stop")
                    } else {
                        Button(L10n.text("Turn On")) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            manager.startKeepingAwake(for: appState.keepAwakeDuration)
                        }
                        .accessibilityIdentifier("keep-awake-start")
                    }
                }
                .frame(width: 140, height: 48, alignment: .trailing)
            }
            if let error = manager.awakeError { errorText(error) }
            Divider()
            HStack(spacing: 12) {
                toolIcon("keyboard", color: .cyan)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keyboard Cleaning").font(.headline).accessibilityIdentifier("tools-cleaning-title")
                    Text("Lock the keyboard until you click End Cleaning.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                .frame(width: 140, height: 48, alignment: .trailing)
            }
            if let error = manager.cleaningError { errorText(error) }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tools-content")
    }

    private var customDurationEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Duration").font(.headline)
            SettingNumberField(title: "Custom Duration", value: $appState.keepAwakeCustomMinutes,
                range: 1...1440, unit: "minutes", step: 1, identifier: "keep-awake-custom-minutes")
            Text("1–1440 minutes").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("Done")) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    showsCustomDuration = false
                }
                .accessibilityIdentifier("keep-awake-custom-done")
            }
        }.padding(20).frame(width: 260)
    }

    private func toolIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color)
            .frame(width: 28, height: 48)
    }

    private var cleaningContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 28)).foregroundStyle(.cyan)
            Text("Keyboard Locked").font(.headline)
            Text(manager.cleaningState == .releasing
                 ? L10n.text("Release all keys to finish cleaning.")
                 : L10n.text("Clean your keyboard. Click below when you are done."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L10n.text("End Cleaning")) { manager.endCleaning() }
                .buttonStyle(.borderedProminent).controlSize(.large)
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

struct KeepAwakeDurationPicker: View {
    @Binding var selection: KeepAwakeDuration
    var holdsIslandPresentation = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.islandContentActive) private var contentActive
    @State private var menuInteraction: IslandInteractionToken?

    var body: some View {
        Picker(L10n.text("Duration"), selection: $selection) {
            ForEach(KeepAwakeDuration.allCases) { option in Text(option.title).tag(option) }
        }
        .labelsHidden().pickerStyle(.menu)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Duration"))
        .accessibilityIdentifier("keep-awake-duration")
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if holdsIslandPresentation, contentActive, menuInteraction == nil {
                menuInteraction = appState.beginControlInteraction(for: .tools)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in releaseMenu() }
        .onChange(of: contentActive) { _, active in if !active { releaseMenu() } }
        .onDisappear { releaseMenu() }
    }

    private func releaseMenu() {
        if let token = menuInteraction { menuInteraction = nil; appState.endControlInteraction(token) }
    }
}

struct ToolsExpandedView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        Button { appState.presentFullExpandedModule(.tools) } label: {
            Label(L10n.text("Open Tools"), systemImage: "wrench.and.screwdriver")
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
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
