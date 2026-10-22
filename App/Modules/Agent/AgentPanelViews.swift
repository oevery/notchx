import AppKit
import SwiftUI

private struct AgentPanelMeasurements: Equatable {
    var content: CGFloat = 0
    var footer: CGFloat = 0
    var total: CGFloat { content + (footer > 0 ? 12 + footer : 0) }
}

private struct AgentPanelContentHeightKey: PreferenceKey {
    static let defaultValue = AgentPanelMeasurements()
    static func reduce(value: inout AgentPanelMeasurements, nextValue: () -> AgentPanelMeasurements) {
        let next = nextValue()
        value.content = max(value.content, next.content)
        value.footer = max(value.footer, next.footer)
    }
}

@MainActor
private enum AgentBrandAssets {
    static let codex = Bundle.main.url(forResource: "codex", withExtension: "png", subdirectory: "AgentIcons").flatMap(NSImage.init(contentsOf:))
    static let claude = Bundle.main.url(forResource: "claude", withExtension: "png", subdirectory: "AgentIcons").flatMap(NSImage.init(contentsOf:))
}

struct AgentBrandIcon: View {
    var provider = "codex.local.catalog"
    var size: CGFloat = 22
    var template = false
    var body: some View {
        Group {
            if let image = provider.hasPrefix("codex") ? AgentBrandAssets.codex : provider.hasPrefix("claude") ? AgentBrandAssets.claude : nil {
                Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFit()
            } else { Image(systemName: "terminal").resizable().scaledToFit() }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct AgentCompactLeadingView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = AgentManager.shared
    var body: some View {
        Button { appState.presentFullExpandedModule(.agent) } label: {
            CompactSlot(kind: .brand) { size in
                AgentBrandIcon(provider: manager.currentGroup?.id.providerID ?? "codex.local.catalog", size: size)
            }
        }
        .buttonStyle(.plain).help(L10n.text("Preview sessions"))
        .accessibilityLabel(L10n.text("Preview sessions"))
        .accessibilityIdentifier("agent-compact-provider")
    }
}

struct AgentCompactCountView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = AgentManager.shared
    var body: some View {
        Button { manager.showSessionList(); appState.presentFullExpandedModule(.agent) } label: {
            CompactSlotCount(count: manager.liveGroups.count)
        }
        .buttonStyle(.plain).help(L10n.format("%d sessions", manager.liveGroups.count))
        .accessibilityLabel(L10n.format("%d sessions", manager.liveGroups.count))
        .accessibilityIdentifier("agent-compact-count")
    }
}

struct AgentCompactView: View {
    var body: some View { HStack { AgentCompactLeadingView(); Spacer(minLength: 8); AgentCompactCountView() } }
}

struct AgentExpandedView: View {
    @ObservedObject private var manager = AgentManager.shared
    var body: some View {
        if let group = manager.currentGroup {
            HStack { AgentBrandIcon(); Text(verbatim: group.root.title).lineLimit(1); Spacer(); Text(verbatim: group.status.displayName).font(.caption).foregroundStyle(.secondary) }
        } else { AgentUnavailableView(connection: manager.connection, isIntegrationEnabled: manager.isCodexActive) }
    }
}

struct AgentFullExpandedView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.islandContentActive) private var contentActive
    @Environment(\.islandMotion) private var motion
    @ObservedObject private var manager: AgentManager
    @State private var hoveringList = false
    @State private var expandedPlan: AgentSessionID?
    @State private var expandedChildren: AgentSessionID?
    @State private var showsRecentSessions = false
    @FocusState private var focusedRow: AgentSessionID?

    init(manager: AgentManager? = nil) { self.manager = manager ?? .shared }

    var body: some View {
        Group {
            if manager.groups.isEmpty {
                AgentUnavailableView(connection: manager.connection, isIntegrationEnabled: manager.isCodexActive)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: AgentPanelContentHeightKey.self, value: AgentPanelMeasurements(content: geometry.size.height))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 12) {
                  ScrollViewReader { scroll in
                    StableScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            navigation
                            IslandPageTransition(key: scrollRoute) {
                            switch manager.panel.route {
                            case .approval(let id):
                                if let request = manager.interaction.approvals.first(where: { $0.id == id }) {
                                    AgentApprovalPanel(request: request, manager: manager)
                                }
                            case .detail(let id):
                                if let group = manager.groups.first(where: { $0.id == id }) { detail(group) }
                            case .sessions:
                                if !manager.panel.prefersSessionList, let group = manager.defaultDetailGroup { detail(group) }
                                else { sessions }
                            }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("agent-panel-top")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: AgentPanelContentHeightKey.self, value: AgentPanelMeasurements(content: geometry.size.height))
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: scrollRoute) { _, _ in scroll.scrollTo("agent-panel-top", anchor: .top) }
                  }
                  if let group = detailGroup {
                    footer(group)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: AgentPanelContentHeightKey.self, value: AgentPanelMeasurements(footer: geometry.size.height))
                            }
                        }
                  }
                }
            }
        }
        .onChange(of: focusedRow) { _, _ in updateListInteraction() }
        .onPreferenceChange(AgentPanelContentHeightKey.self) { measurements in
            if contentActive { appState.updateAgentPanelContentHeight(measurements.total) }
        }
        .onDisappear { manager.leavePanel() }
        .onChange(of: contentActive) { _, active in if !active { manager.leavePanel() } }
        // Natural content is laid out at its destination size. Interpolating
        // each measured row would feed intermediate heights back into the host.
        .modifier(IslandNaturalLayout())
    }

    private var scrollRoute: AgentPanelRoute {
        if manager.panel.route == .sessions, !manager.panel.prefersSessionList, let group = manager.defaultDetailGroup {
            return .detail(group.id)
        }
        return manager.panel.route
    }

    private var detailGroup: AgentSessionGroup? {
        if case .detail(let id) = scrollRoute { return manager.groups.first { $0.id == id } }
        return nil
    }

    @ViewBuilder private var navigation: some View {
        HStack(spacing: 8) {
            if manager.panel.route != .sessions || !manager.panel.prefersSessionList && manager.defaultDetailGroup != nil && !manager.recentGroups.isEmpty {
                Button { manager.showSessionList() } label: { Label("Back to sessions", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            } else if manager.liveGroups.count > 1 { Text(L10n.format("%d sessions", manager.liveGroups.count)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if !manager.interaction.approvals.isEmpty, !showingApproval {
                Button { if let first = manager.interaction.approvals.first { manager.showApproval(first.id) } } label: {
                    Text(L10n.format("%d need attention", manager.interaction.approvals.count))
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private var showingApproval: Bool { if case .approval = manager.panel.route { return true }; return false }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            sessionRows(manager.liveGroups)
            if !manager.recentGroups.isEmpty {
                IslandDisclosureButton(expanded: showsRecentSessions, action: { showsRecentSessions.toggle() }) {
                    Text(L10n.text("Recent sessions"))
                }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                .accessibilityIdentifier("agent-toggle-recent")
                if showsRecentSessions {
                    sessionRows(manager.recentGroups)
                        .transition(.opacity.animation(motion.content))
                }
            }
        }
        .onHover { hoveringList = $0; updateListInteraction() }
        .onDisappear { hoveringList = false; focusedRow = nil; manager.setListInteracting(false) }
    }
    private func sessionRows(_ groups: [AgentSessionGroup]) -> some View {
            ForEach(groups) { group in
                Button {
                    manager.selectSession(group.id)
                    if let request = manager.interaction.approvals.first(where: { request in request.sessionID == group.id || group.children.contains(where: { $0.id == request.sessionID }) }) { manager.showApproval(request.id) }
                } label: {
                    HStack(spacing: 10) {
                        AgentBrandIcon(provider: group.id.providerID, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: group.root.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            AgentMetadataLine(group: group, context: manager.interaction.contexts[group.id], compact: true)
                            AgentSessionActivity(group: group, context: manager.interaction.contexts[group.id], tool: manager.interaction.tools[group.id])
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: group.status.displayName).font(.caption).foregroundStyle(group.status.isWaiting ? .orange : .secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(10).contentShape(Rectangle())
                    .background(manager.selectedSessionID == group.id ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).focused($focusedRow, equals: group.id)
                .accessibilityIdentifier("agent-select-" + group.id.sessionID)
            }
    }
    private func updateListInteraction() { manager.setListInteracting(hoveringList || focusedRow != nil) }

    private func detail(_ group: AgentSessionGroup) -> some View {
        let context = manager.interaction.contexts[group.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: group.root.title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Label(group.status.displayName, systemImage: group.status.icon).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            AgentMetadataLine(group: group, context: context)
            if context?.cwd == nil && context?.model == nil {
                Text("Session details are incomplete. Check the hook helper in Agent settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = AgentPanelPresentation.userMessage(context: context, turnID: group.root.runID) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("You").foregroundStyle(.secondary).fontWeight(.medium)
                    Text(verbatim: prompt).lineLimit(1).truncationMode(.tail)
                }.font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent-user-message-" + group.id.sessionID)
            }
            AgentSessionActivity(group: group, context: context, tool: manager.interaction.tools[group.id])
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent-current-activity-" + group.id.sessionID)
            if let input = context?.pendingInput {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("Needs your answer"), systemImage: "questionmark.bubble").foregroundStyle(.orange)
                    Text(verbatim: input.text).font(.callout).lineLimit(2)
                    Button { manager.openSession(group.id) { appState.openExternalURL($0, for: .agent) } } label: {
                        Label(L10n.text("Answer in Codex"), systemImage: "arrow.up.right")
                    }.buttonStyle(.plain).font(.callout).disabled(!manager.canOpenSession(group.id))
                        .accessibilityIdentifier("agent-answer-in-codex-" + group.id.sessionID)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent-pending-input-" + group.id.sessionID)
            }
            if expandedPlan == group.id, let steps = context?.plan, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step.step, systemImage: step.status == "completed" ? "checkmark.circle" : "circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.accessibilityIdentifier("agent-plan-" + group.id.sessionID)
                    .transition(.opacity.animation(motion.content))
            }
            if expandedChildren == group.id {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.children) { child in
                        HStack {
                            Text(verbatim: child.title).lineLimit(1)
                            Spacer()
                            if let known = manager.interaction.contexts[child.id]?.lastKnownStatus {
                                Text(verbatim: L10n.format("Last known: %@", known.displayName))
                            } else { Text(verbatim: child.status.displayName) }
                        }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("agent-children-" + group.id.sessionID)
                    .transition(.opacity.animation(motion.content))
            }
        }
        .id(group.id)
    }

    private func footer(_ group: AgentSessionGroup) -> some View {
        VStack(spacing: 10) {
            AgentMessageComposer(manager: manager, sessionID: group.id).id(group.id)
            Divider()
            HStack(spacing: 10) {
                Text(group.root.updatedAt, style: .time).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("agent-time-" + group.id.sessionID)
                if let steps = manager.interaction.contexts[group.id]?.plan, !steps.isEmpty {
                    IslandDisclosureButton(expanded: expandedPlan == group.id, action: { expandedPlan = expandedPlan == group.id ? nil : group.id }) {
                        Text(verbatim: L10n.format("Task list %d/%d", steps.filter { $0.status == "completed" }.count, steps.count))
                    }.accessibilityIdentifier("agent-toggle-plan-" + group.id.sessionID)
                }
                if !group.children.isEmpty {
                    IslandDisclosureButton(expanded: expandedChildren == group.id, action: { expandedChildren = expandedChildren == group.id ? nil : group.id }) {
                        Text(verbatim: L10n.format("%d subagents", group.children.count))
                    }.accessibilityIdentifier("agent-toggle-children-" + group.id.sessionID)
                }
                Spacer(minLength: 8)
                Button { manager.openSession(group.id) { appState.openExternalURL($0, for: .agent) } } label: {
                    Label("Open session", systemImage: "arrow.up.right").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!manager.canOpenSession(group.id))
                .accessibilityIdentifier("agent-open-" + group.id.sessionID)
            }
            .font(.caption).lineLimit(1).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-footer-" + group.id.sessionID)
    }
}

/// Drafts belong to the session; focus and its presentation hold belong only
/// to this editor's visible lifetime. Previewing never requests focus.
struct AgentMessageComposer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.islandContentActive) private var contentActive
    @ObservedObject var manager: AgentManager
    let sessionID: AgentSessionID
    @FocusState private var isFocused: Bool
    @State private var interactionToken: IslandInteractionToken?

    private var draft: AgentMessageDraft { manager.draft(for: sessionID) }
    private var mode: AgentMessageMode { manager.messageMode(for: sessionID) }
    private var focusBinding: Binding<Bool> { Binding(get: { isFocused }, set: { isFocused = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(L10n.text("Add a message..."), text: Binding(
                    get: { manager.draft(for: sessionID).text },
                    set: { manager.setMessageDraft($0, for: sessionID) }), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).focused($isFocused)
                    .frame(minHeight: 28)
                    .onSubmit { submit(mode) }
                    .background(IslandTextInputFocusBoundary(isFocused: focusBinding))
                    .accessibilityIdentifier("agent-message-input")
                HStack(alignment: .center, spacing: 10) {
                    if mode == .steer {
                        Button("Queue") { submit(.queue) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .frame(height: 28)
                            .disabled(!manager.canSendMessage(to: sessionID, mode: .queue))
                            .help(L10n.text("Send after this turn ends"))
                            .accessibilityIdentifier("agent-message-queue")
                    }
                    Button { submit(mode) } label: {
                        ZStack {
                            Text(L10n.text(mode == .send ? "Send" : "Steer"))
                                .opacity(draft.delivery == .sending ? 0 : 1)
                            if draft.delivery == .sending { ProgressView().controlSize(.small) }
                        }.frame(minWidth: 34)
                    }
                    .buttonStyle(.bordered).controlSize(.regular).frame(height: 28)
                    .disabled(!manager.canSendMessage(to: sessionID, mode: mode))
                    .accessibilityLabel(L10n.text(mode == .send ? "Send" : "Steer"))
                    .accessibilityIdentifier("agent-message-primary")
                }
            }
            .padding(10).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Group {
                switch draft.delivery {
                case .sending: Text("Sending...")
                case .accepted: Text(L10n.text(draft.request?.mode == .queue ? "Added to queue" : "Accepted by Codex"))
                case .failed: Text("Not sent. The draft has been preserved.")
                case .uncertain:
                    Text("Delivery unconfirmed. Check the original session before sending again.")
                    Button("I checked the original session") { manager.acknowledgeUncertainMessage(for: sessionID) }
                        .buttonStyle(.plain).accessibilityIdentifier("agent-message-acknowledge")
                case .ready:
                    if draft.text.utf8.count > 32_000 { Text("Message is too long. Limit: 32 KB.") }
                    else if manager.interaction.primaryCapabilities[sessionID]?.contains(mode.capability) != true {
                        Text("Message delivery unavailable. Open the original session to continue.")
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: isFocused) { _, focused in
            if focused && contentActive {
                manager.setPanelEditing(true)
                if interactionToken == nil { interactionToken = appState.beginControlInteraction(for: .agent) }
            } else { releaseEditing() }
        }
        .onChange(of: contentActive) { _, active in if !active { releaseEditing() } }
        .onChange(of: appState.presentationHandoffs) { _, sessions in if !sessions.isEmpty { releaseEditing() } }
        .onDisappear { releaseEditing() }
    }

    private func submit(_ mode: AgentMessageMode) { manager.sendMessage(to: sessionID, mode: mode) }
    private func releaseEditing() {
        isFocused = false
        if let token = interactionToken { interactionToken = nil; appState.endControlInteraction(token) }
        if manager.panel.isEditing { manager.setPanelEditing(false) }
    }
}

private struct AgentSessionActivity: View {
    let group: AgentSessionGroup
    let context: AgentSessionContext?
    let tool: String?
    var body: some View {
        if let activity = AgentPanelPresentation.activity(group: group, context: context, tool: tool) {
            AgentActivityPreview(activity: activity)
        }
    }
}

private struct AgentActivityPreview: View {
    let activity: AgentCurrentActivity
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.symbol).frame(width: 14, height: 14)
            Text(verbatim: presentation.text).lineLimit(1).truncationMode(.tail)
        }
        .frame(height: 18, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var presentation: AgentActivityPresentation { AgentActivityPresentation(activity: activity) }
}

/// Shared by list and detail. Complete localized sentences keep grammar and
/// status together while file names, commands and public commentary stay verbatim.
struct AgentActivityPresentation {
    let symbol: String
    let text: String

    init(activity: AgentCurrentActivity) {
        switch activity {
        case .waiting:
            symbol = "ellipsis"; text = L10n.text("Running · No detailed progress")
        case .progress(let progress):
            symbol = "text.bubble"; text = progress
        case .tool(let name, let detail):
            let kind = AgentToolKind(name: name)
            symbol = kind.symbol; text = L10n.format(kind.template(outcome: nil), kind.object(name: name, detail: detail))
        case .completedTool(let name, let detail, let outcome):
            let kind = AgentToolKind(name: name)
            symbol = kind.symbol; text = L10n.format(kind.template(outcome: outcome), kind.object(name: name, detail: detail))
        }
    }
}

private struct AgentMetadataLine: View {
    let group: AgentSessionGroup
    let context: AgentSessionContext?
    var compact = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { fields }
            VStack(alignment: .leading, spacing: 3) { fields }
        }.font(.callout).foregroundStyle(.secondary)
    }
    @ViewBuilder private var fields: some View {
        Text("Codex")
        if let cwd = context?.cwd { Text(verbatim: URL(fileURLWithPath: cwd).lastPathComponent).help(cwd) }
        if let branch = context?.branch { Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1) }
        if let model = context?.model { Label(model, systemImage: "cpu").lineLimit(1).help(model) }
        if !compact, let start = context?.startedAt { Text(start, style: .time) }
        if !compact { Text(verbatim: "#" + String(group.id.sessionID.prefix(8))) }
    }
}

private struct AgentApprovalPanel: View {
    let request: AgentApproval
    @ObservedObject var manager: AgentManager
    @EnvironmentObject private var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let group = manager.groups.first(where: { $0.id == request.sessionID || $0.children.contains(where: { $0.id == request.sessionID }) }) {
                HStack { AgentBrandIcon(size: 18); Text(verbatim: group.root.title).font(.subheadline.weight(.medium)).lineLimit(1) }
                AgentMetadataLine(group: group, context: manager.interaction.contexts[request.sessionID], compact: true)
            }
            HStack { Label("Approval requested", systemImage: "checkmark.shield").foregroundStyle(.orange); Spacer(); Text(L10n.format("%d pending", manager.interaction.approvals.count)).foregroundStyle(.secondary) }.font(.caption)
            Text(verbatim: request.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if let reason = request.reason { Text(verbatim: reason).font(.caption).foregroundStyle(.secondary) }
            if request.delivery == .uncertain {
                Text("Decision delivery unconfirmed. Check Codex before deciding again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Handle in Codex") { manager.respondToApproval(request.id, decision: .deferToApp); manager.openSession(request.sessionID) { appState.openExternalURL($0, for: .agent) } }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(request.denyEndsTurn ? L10n.text("Cancel turn") : L10n.text("Deny")) { manager.respondToApproval(request.id, decision: .deny) }
                    .disabled(!request.canDeny || request.isSubmitting || request.expiresAt <= Date())
                Button("Allow once") { manager.respondToApproval(request.id, decision: .allow) }.buttonStyle(.borderedProminent)
                    .disabled(!request.canAllow || request.isSubmitting || request.expiresAt <= Date())
                    .accessibilityIdentifier("agent-allow-" + request.id)
            }.font(.caption)
        }
    }
}
