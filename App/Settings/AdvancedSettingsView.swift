import SwiftUI

struct AdvancedSettingsView: View {
    @State private var screenOptions: [ScreenDetector.ScreenOption] = ScreenDetector.availableScreenOptions()
    @ObservedObject private var scheduler = ModuleRefreshScheduler.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Display ────────────────────────────────────────────────────
            SettingSectionLabel(title: "Display selection")
            SettingGroup {
                SettingPickerRow(title: "Show island on", description: "Pick a specific display or let NotchX choose",
                                 selection: $appState.displayIdentifier) {
                    if !appState.displayIdentifier.isEmpty, !screenOptions.contains(where: { $0.id == appState.displayIdentifier }) {
                        Text("Saved display (disconnected)").tag(appState.displayIdentifier)
                    }
                    ForEach(screenOptions) { option in
                        Text(option.id.isEmpty || option.id == ScreenDetector.allDisplaysIdentifier
                             ? L10n.text(option.name) : option.name).tag(option.id)
                    }
                }
            }
            .onAppear { refreshScreenOptions() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )) { _ in refreshScreenOptions() }

            SettingGroup {
                SettingDisclosureGroup(title: "Energy Diagnostics") {
                    if scheduler.diagnostics.isEmpty {
                        SettingNote("No scheduled refresh jobs")
                    } else {
                        ForEach(Array(scheduler.diagnostics.enumerated()), id: \.element.id) { index, job in
                            diagnosticRow(job)
                            if index < scheduler.diagnostics.count - 1 {
                                SettingRowDivider()
                            }
                        }
                    }
                }
            }

            SettingSectionLabel(title: "About")
            SettingGroup {
                SettingRow(title: "Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .monospaced().foregroundStyle(.secondary)
                }
                SettingRowDivider()
                SettingRow(title: "Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                        .monospaced().foregroundStyle(.secondary)
                }
                SettingRowDivider()
                SettingRow(title: "Author") {
                    Text(verbatim: Bundle.main.infoDictionary?["NotchXAuthor"] as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                SettingRowDivider()
                SettingRow(title: "Copyright") {
                    Text(verbatim: Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                SettingRowDivider()
                SettingRow(title: "Updates", description: "NotchX updates are installed manually. Automatic update checks and telemetry are disabled.") {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func diagnosticRow(_ job: EnergyDiagnosticsSnapshot) -> some View {
        SettingRow(title: job.name, description: "\(L10n.text(job.moduleName)) · \(job.policy.localizedLabel)") {
            VStack(alignment: .trailing, spacing: 3) {
                Text(L10n.text(job.status)).foregroundStyle(job.status == "Scheduled" ? .green : .secondary)
                if let duration = job.lastDispatchDuration {
                    Text(L10n.format("Dispatch: %@ ms", String(format: "%.0f", duration * 1000))).monospacedDigit()
                }
                if let nextFireDate = job.nextFireDate { SettingSupportingText(Text("Next \(nextFireDate, style: .relative)")) }
            }.font(SettingTypography.supporting)
        }
    }

    private func refreshScreenOptions() {
        screenOptions = ScreenDetector.availableScreenOptions()
        // The host already falls back when a display is absent. Browsing this
        // page must retain the saved choice for when that display reconnects.
    }
}


// Translate presentation values at render time so changing language also updates
// existing diagnostic snapshots; scheduler IDs and raw status remain stable.
private extension ModuleRefreshPolicy {
    var localizedLabel: String {
        switch self {
        case .eventDriven: return L10n.text("Event driven")
        case .manual: return L10n.text("Manual")
        case .interval(let interval, _): return L10n.format("Every %@", Self.localizedInterval(interval))
        case .activeOnly(let interval, _): return L10n.format("Active every %@", Self.localizedInterval(interval))
        case .visibleOnly(let interval, _), .presentationOnly(let interval, _): return L10n.format("Visible every %@", Self.localizedInterval(interval))
        }
    }

    static func localizedInterval(_ interval: TimeInterval) -> String {
        if interval >= 60 { return L10n.format("%d min", Int(interval / 60)) }
        return L10n.format("%.1f s", interval)
    }
}
