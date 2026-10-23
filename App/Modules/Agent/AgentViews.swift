import AppKit
import SwiftUI

extension AgentActivityStatus {
    var displayName: String {
        switch self {
        case .running: return L10n.text("Running")
        case .waitingInput: return L10n.text("Needs your answer")
        case .waitingApproval: return L10n.text("Waiting for approval")
        case .completed: return L10n.text("Turn ended")
        case .failed: return L10n.text("Failed")
        case .cancelled: return L10n.text("Cancelled")
        case .idle: return L10n.text("Idle")
        case .unknown: return L10n.text("Activity unavailable")
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle"
        case .waitingInput, .waitingApproval: return "exclamationmark.bubble"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "stop.circle"
        case .idle: return "pause.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct AgentUnavailableView: View {
    var connection: AgentSourceConnection = .unconfigured
    var descriptionFont: Font = .caption
    var isIntegrationEnabled = true

    private var message: String {
        guard isIntegrationEnabled else { return L10n.text("Codex integration is off") }
        switch connection {
        case .unconfigured: return L10n.text("Agent not configured")
        case .disconnected: return L10n.text("Agent source disconnected")
        case .connected: return L10n.text("No live Codex sessions")
        case .permissionDenied: return L10n.text("Agent source access denied")
        case .unsupportedSchema: return L10n.text("Agent source format unsupported")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message).font(.subheadline.weight(.semibold))
            Text(!isIntegrationEnabled
                 ? L10n.text("Enable Codex in Agent settings to receive activity. Hooks can still be managed.")
                 : connection == .connected
                 ? L10n.text("Sessions use existing Codex connections for live activity, with Hooks as fallback.")
                 : L10n.text("No live session has been confirmed. Open a Codex chat or check the connection in Agent settings."))
                .font(descriptionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentSettingsDetail: View {
    @ObservedObject private var manager: AgentManager
    @StateObject private var integration: AgentIntegrationController
    @State private var destination: AgentSettingsDestination?

    init(manager: AgentManager? = nil, integration: AgentIntegrationController? = nil) {
        self.manager = manager ?? .shared
        _integration = StateObject(wrappedValue: integration ?? AgentIntegrationController())
    }

    private var connectionStatus: String {
        guard integration.hasRefreshed else { return "Checking..." }
        return integration.isInstalled ? "Configured" : "Not configured"
    }

    private var activityStatus: String {
        guard manager.isCodexActive else { return "Off" }
        let kinds = Set(manager.interaction.primaryChannels.values)
        if kinds.contains(.desktop) && kinds.contains(.daemon) { return "Desktop and CLI connected" }
        if kinds.contains(.desktop) { return "Desktop connected" }
        if kinds.contains(.daemon) { return "CLI connected" }
        guard manager.interaction.isListening else { return "Not connected" }
        return manager.interaction.receivedEvents > 0 ? "Events received" : "Waiting for activity"
    }

    private var hookStatus: String {
        guard manager.isCodexActive else { return integration.isInstalled ? "Configured" : "Not configured" }
        guard manager.codexHookFallbackEnabled else {
            return manager.interaction.hookManagement == .waitingForRefresh ? "Disabled; Codex refresh pending" : "Off"
        }
        switch manager.interaction.hookManagement {
        case .waitingForTrust: return "Review Hooks in Codex"
        case .waitingForRefresh: return "Waiting for runtime refresh"
        case .suspended: return "Not needed while connected"
        case .ready: return "Hooks ready as fallback"
        default: return integration.isInstalled ? "On when needed" : connectionStatus
        }
    }

    private var helperWarning: String? {
        guard integration.isInstalled else { return nil }
        switch integration.helperStatus {
        case .current: return nil
        case .outdated: return "Update the helper to receive current activity."
        case .missing: return "Restore the helper to receive activity."
        case .unavailable: return "The connection helper could not be verified."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingSectionLabel(title: "Integrations")
            SettingGroup {
                SettingContent {
                    HStack(spacing: 10) {
                        AgentSettingsApplicationIcon()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "Codex").font(.headline)
                            if manager.isCodexActive { SettingSupportingText("Connects to your existing Desktop and CLI sessions.") }
                        }
                        Spacer(minLength: 8)
                        SettingSwitch(title: "Enable Codex integration", isOn: Binding(get: { manager.codexEnabled }, set: { manager.setCodexEnabled($0) }))
                            .disabled(!manager.isEnabled)
                            .help(L10n.text(!manager.isEnabled
                                ? "The Agent module is off. Your integration choices are kept; Hooks can still be managed."
                                : !manager.codexEnabled
                                ? "Codex integration is off. Its helper stops processing; saved Hooks remain available."
                                : "Enable Codex integration"))
                            .accessibilityIdentifier("agent-codex-enabled")
                    }
                }
                if manager.isCodexActive {
                    SettingRowDivider()
                    SettingRow(title: "Status updates", description: manager.interaction.hookFallbackNeeded
                        ? "Open a Codex chat to connect. For clients without a live connection, you can enable fallback Hooks below."
                        : "Uses existing Desktop IPC and CLI daemon connections. No extra service is started.") {
                        Text(verbatim: L10n.text(activityStatus)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("agent-setting-activity")
                        Button("Check connection") { manager.refreshConnection(); Task { await integration.refresh() } }
                            .disabled(integration.isWorking || !integration.hasRefreshed)
                            .accessibilityIdentifier("agent-check-connection")
                    }
                    SettingRowDivider()
                    SettingRow(title: "Fallback Hooks", description: "Optional. Installs only when enabled and needed; review new or changed Hooks in Codex.") {
                        SettingSwitch(title: "Use fallback Hooks", isOn: Binding(get: { manager.codexHookFallbackEnabled }, set: { manager.setCodexHookFallbackEnabled($0) }))
                            .disabled(integration.isWorking)
                            .accessibilityIdentifier("agent-hook-fallback-enabled")
                    }
                }
                SettingRowDivider()
                SettingRow(title: "Hooks configuration", description: manager.codexHookFallbackEnabled ? helperWarning : nil) {
                    Text(verbatim: L10n.text(hookStatus)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("agent-setting-connection")
                    Button(L10n.text("Manage")) { destination = .hooks }
                        .disabled(!integration.hasRefreshed || integration.isWorking)
                        .accessibilityIdentifier("agent-manage-hooks")
                }
                if manager.isCodexActive {
                    SettingDisclosureGroup(title: "Connection diagnostics", identifier: "agent-connection-diagnostics") {
                        VStack(alignment: .leading, spacing: 8) { diagnostics }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = integration.errorKey {
                        SettingContent { Text(verbatim: L10n.text(error)).foregroundStyle(.red).font(.callout) }
                    }
                }
            }
        }
        .task { await integration.refresh() }
        .onChange(of: manager.interaction.hookManagement) { _, _ in
            Task { await integration.refresh() }
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .hooks: AgentHookManagementView(integration: integration, manager: manager)
            }
        }
    }

    @ViewBuilder private var diagnostics: some View {
        if manager.groups.isEmpty {
            AgentUnavailableView(connection: manager.connection, descriptionFont: SettingTypography.supporting, isIntegrationEnabled: manager.isCodexActive)
        } else {
            Text(L10n.format("%d live sessions", manager.liveGroups.count))
            SettingSupportingText("Only sessions confirmed by a live source are shown.")
        }
        Text(!manager.codexHookFallbackEnabled ? L10n.text("Fallback Hooks are off")
            : manager.interaction.isListening ? L10n.text("Hook listener ready") : L10n.text("Not needed while connected"))
        Text(L10n.format("Primary connections: %d sessions", manager.interaction.primaryChannels.count)).font(.callout)
        SettingSupportingText("Live connections are preferred. Hooks are optional and are never installed just by enabling Codex integration.")
        Text(L10n.format("%d hook events received", manager.interaction.receivedEvents)).font(.callout)
            .accessibilityIdentifier("agent-diagnostic-event-count")
        Text(L10n.format("Tool events: %d started, %d ended",
            manager.interaction.eventCounts["PreToolUse", default: 0],
            manager.interaction.eventCounts["PostToolUse", default: 0])).font(.callout)
        if manager.interaction.rejectedEvents > 0 {
            Text(L10n.format("%d hook events ignored", manager.interaction.rejectedEvents)).font(.caption).foregroundStyle(.secondary)
            ForEach(manager.interaction.rejectionCounts.keys.sorted(), id: \.self) { reason in
                Text(L10n.format("%@ · %d", rejectionLabel(reason), manager.interaction.rejectionCounts[reason, default: 0])).font(.caption).foregroundStyle(.secondary)
            }
        }
        Text(L10n.format("Live progress: %d observers, %d updates", manager.interaction.liveObserverCount, manager.interaction.liveProgressUpdates)).font(.caption).foregroundStyle(.secondary)
        SettingSupportingText("Public progress and questions use new records from verified live chats. Start a new turn after updating the helper.")
        Text(integration.isInstalled ? L10n.text("Hooks configured; review new or changed hooks in Codex.") : L10n.text("Codex hooks are not installed."))
            .font(.callout).foregroundStyle(.secondary)
        if integration.isInstalled {
            switch integration.helperStatus {
            case .current: SettingSupportingText("The installed helper matches this app.")
            case .outdated: SettingSupportingText("The installed helper differs from this app. Update it to enable public progress and question notifications.")
            case .missing: SettingSupportingText("The configured helper is missing. Restore it to receive Codex events.")
            case .unavailable: SettingSupportingText("The helper could not be verified. Check file ownership and rebuild the complete app bundle.")
            }
        }
        SettingSupportingText("NotchX maintains only its own Hook entries and creates a backup. New or changed Hooks require trust in Codex.")
        SettingSupportingText("The helper reads bounded metadata from the current hook transcript to identify child threads and the approval reviewer. Unknown or automatic reviewers stay with Codex.")
    }

    private func rejectionLabel(_ reason: String) -> String {
        switch reason {
        case "identity": return L10n.text("Transcript identity not verified")
        case "oldTurn": return L10n.text("Event belongs to another turn")
        case "missingTurn": return L10n.text("Event has no turn identity")
        case "unknown": return L10n.text("Session not verified")
        case "closed": return L10n.text("Turn already closed")
        case "duplicate": return L10n.text("Duplicate event")
        case "expired": return L10n.text("Expired event")
        case "finishedTool": return L10n.text("Tool already finished")
        default: return L10n.text("Invalid event")
        }
    }
}

/// The settings surface owns one icon lookup; live events never resolve it again.
@MainActor
private final class AgentSettingsIconSource: ObservableObject {
    let image: NSImage?

    init() {
        image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct AgentSettingsApplicationIcon: View {
    @StateObject private var source = AgentSettingsIconSource()

    var body: some View {
        Group {
            if let image = source.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                AgentBrandIcon(size: 20, template: true).foregroundStyle(.primary)
            }
        }
        .frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

private enum AgentSettingsDestination: String, Identifiable {
    case hooks
    var id: String { rawValue }
}

private struct AgentSettingsSheet<Content: View, Actions: View>: View {
    let title: String
    let description: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SettingPageHeader(title: L10n.text(title))
                SettingSupportingText(description)
            }
            content
            Divider()
            actions.controlSize(.regular)
        }
        .padding(20).frame(width: 560).fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentHookManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var integration: AgentIntegrationController
    @ObservedObject var manager: AgentManager

    private var needsHelperRepair: Bool {
        integration.isInstalled && (integration.helperStatus == .outdated || integration.helperStatus == .missing)
    }

    private var helperStatus: String {
        guard integration.hasRefreshed else { return "Checking..." }
        switch integration.helperStatus {
        case .current: return "Matches this app"
        case .outdated: return "Update available"
        case .missing: return "Not installed"
        case .unavailable: return "Not verified"
        }
    }

    var body: some View {
        AgentSettingsSheet(title: "Codex Hooks", description: "Fallback runs only when Codex integration is enabled and a live connection is unavailable. Installing Hooks does not enable them.") {
            SettingGroup {
                SettingRow(title: "Hooks configuration") {
                    Text(verbatim: L10n.text(!integration.hasRefreshed ? "Checking..." : integration.isInstalled ? "Configured" : "Not configured"))
                        .foregroundStyle(.secondary).accessibilityIdentifier("agent-hook-configuration-status")
                    if integration.isInstalled {
                        Button("Reconfigure connection") { integration.install() }
                            .disabled(integration.isWorking || !integration.hasRefreshed)
                            .accessibilityIdentifier("agent-reconfigure-hooks")
                    }
                }
                SettingRowDivider()
                SettingRow(title: "Hook helper") {
                    Text(verbatim: L10n.text(helperStatus)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("agent-hook-helper-status")
                }
            }
            SettingGroup {
                SettingDisclosureGroup(title: "Review hook configuration", identifier: "agent-hook-preview-toggle") {
                    StableScrollView([.horizontal, .vertical]) {
                        Text(verbatim: integration.preview).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("agent-hook-configuration-preview")
                    }.frame(height: 160)
                }
            }
            SettingSupportingText("NotchX maintains only its own Hook entries and creates a backup. New or changed Hooks require trust in Codex.")
            if let error = integration.errorKey { Text(verbatim: L10n.text(error)).foregroundStyle(.red).font(.callout) }
        } actions: {
            HStack(spacing: 12) {
                if integration.isInstalled {
                    Button("Remove NotchX hooks", role: .destructive) {
                        manager.setCodexHookFallbackEnabled(false)
                        integration.remove()
                    }
                        .buttonStyle(.bordered)
                        .disabled(integration.isWorking || !integration.hasRefreshed)
                        .accessibilityIdentifier("agent-remove-hooks")
                }
                Spacer(minLength: 12)
                if !integration.isInstalled || needsHelperRepair {
                    doneButton.keyboardShortcut(.cancelAction)
                    if !integration.isInstalled {
                        Button("Configure connection") { integration.install() }
                            .accessibilityIdentifier("agent-configure-connection")
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(integration.isWorking || !integration.hasRefreshed)
                    } else {
                        Button(L10n.text(integration.helperStatus == .missing ? "Restore hook helper" : "Update hook helper")) { integration.updateHelper() }
                            .accessibilityIdentifier("agent-update-helper")
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(integration.isWorking || !integration.hasRefreshed)
                    }
                } else {
                    doneButton.keyboardShortcut(.defaultAction)
                }
            }
        }
        .onExitCommand { dismiss() }
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }.buttonStyle(.bordered)
            .accessibilityIdentifier("agent-settings-sheet-done")
    }
}
