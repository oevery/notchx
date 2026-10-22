import AppKit
import Combine
import Foundation

/// Module boundary. Provider sources manage their own integration files;
/// enabling the module never approves Hooks or requests OS permissions.
@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager(sourceFactory: { CodexLiveStatusSource() }, preferenceStore: .standard)
    static let codexEnabledKey = "module.agent.codex.enabled"
    static let codexHookFallbackKey = "module.agent.codex.hookFallbackEnabled"

    @Published private(set) var isEnabled = false
    @Published private(set) var codexEnabled: Bool
    @Published private(set) var codexHookFallbackEnabled: Bool
    @Published private(set) var groups: [AgentSessionGroup] = []
    @Published private(set) var attentionCount = 0
    @Published private(set) var connection = AgentSourceConnection.unconfigured
    @Published private(set) var navigationTargets: [AgentSessionID: AgentVerifiedNavigationTarget] = [:]
    @Published private(set) var interaction = AgentInteractionSnapshot()
    @Published private(set) var selectedSessionID: AgentSessionID?
    @Published private(set) var panel = AgentPanelState()
    @Published private(set) var attentionRequestID: String?
    @Published private(set) var messageDrafts: [AgentSessionID: AgentMessageDraft] = [:]
    private var messageTasks: [AgentSessionID: Task<Void, Never>] = [:]
    private let sourceFactory: @MainActor () -> AgentStatusSource?
    private let handlerBundleIdentifier: @MainActor (URL) -> String?
    private let preferenceStore: UserDefaults?
    private var source: AgentStatusSource?
    private var store = AgentSessionStore()
    private var generation = UUID()

    init(
        sourceFactory: @escaping @MainActor () -> AgentStatusSource? = { nil },
        handlerBundleIdentifier: @escaping @MainActor (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        preferenceStore: UserDefaults? = nil
    ) {
        self.sourceFactory = sourceFactory
        self.handlerBundleIdentifier = handlerBundleIdentifier
        self.preferenceStore = preferenceStore
        codexEnabled = preferenceStore?.object(forKey: Self.codexEnabledKey) as? Bool ?? true
        codexHookFallbackEnabled = preferenceStore?.bool(forKey: Self.codexHookFallbackKey) ?? false
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        reconcileSource()
    }

    var isCodexActive: Bool { isEnabled && codexEnabled }

    func setCodexEnabled(_ enabled: Bool) {
        guard codexEnabled != enabled else { return }
        codexEnabled = enabled
        preferenceStore?.set(enabled, forKey: Self.codexEnabledKey)
        reconcileSource()
    }

    func setCodexHookFallbackEnabled(_ enabled: Bool) {
        guard codexHookFallbackEnabled != enabled else { return }
        codexHookFallbackEnabled = enabled
        preferenceStore?.set(enabled, forKey: Self.codexHookFallbackKey)
        (source as? AgentInteractiveSource)?.setHookFallbackEnabled(enabled)
    }

    private func reconcileSource() {
        generation = UUID()
        for (id, task) in messageTasks {
            task.cancel()
            messageDrafts[id]?.delivery = .uncertain
        }
        messageTasks.removeAll()
        source?.stop()
        source = nil
        if isCodexActive {
            source = sourceFactory()
        }
        if let source {
            let expectedGeneration = generation
            (source as? AgentInteractiveSource)?.setHookFallbackEnabled(codexHookFallbackEnabled)
            source.start { [weak self] update in
                self?.receive(update, generation: expectedGeneration)
            }
        } else {
            store.reset()
            navigationTargets.removeAll()
            interaction = AgentInteractionSnapshot()
            selectedSessionID = nil
            panel = AgentPanelState()
            attentionRequestID = nil
            connection = isCodexActive ? .unconfigured : .disconnected
            publishSnapshot()
        }
    }

    /// Sources retain this generation on subscription.
    /// Late callbacks after disable/re-enable cannot revive previous sessions.
    var lifecycleGeneration: UUID { generation }

    func receive(_ event: AgentSessionEvent, generation expectedGeneration: UUID) {
        guard isCodexActive, connection == .connected, expectedGeneration == generation, store.ingest(event) else { return }
        publishSnapshot()
    }

    func receive(_ update: AgentSourceUpdate, generation expectedGeneration: UUID) {
        guard isCodexActive, expectedGeneration == generation else { return }
        switch update {
        case .connection(let state):
            guard connection != state else { return }
            connection = state
            if state != .connected {
                store.reset()
                navigationTargets.removeAll()
                publishSnapshot()
            }
        case .retainingSessions(let ids):
            guard connection == .connected, !Set(store.sessions.keys).isSubset(of: ids) else { return }
            store.retainSessions(ids)
            navigationTargets = navigationTargets.filter { ids.contains($0.key) }
            publishSnapshot()
        case .event(let event):
            receive(event, generation: expectedGeneration)
        case .navigation(let sessionID, let target):
            guard connection == .connected, store.sessions[sessionID] != nil, target.url != nil,
                  navigationTargets[sessionID] != target else { return }
            navigationTargets[sessionID] = target
        case .interaction(let snapshot):
            guard interaction != snapshot else { return }
            interaction = snapshot
            reconcilePanel()
        }
    }

    var currentGroup: AgentSessionGroup? {
        groups.first { $0.id == selectedSessionID }
            ?? groups.first { $0.status.isWaiting }
            ?? groups.first { interaction.liveSessionIDs.contains($0.id) && $0.status == .running }
            ?? groups.first
    }

    func selectSession(_ id: AgentSessionID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        panel.route = .detail(id)
    }

    var presentationGroups: [AgentSessionGroup] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        return panel.order.compactMap { byID[$0] }
    }

    var liveGroups: [AgentSessionGroup] {
        presentationGroups.filter { interaction.liveSessionIDs.contains($0.id) }
    }
    var recentGroups: [AgentSessionGroup] {
        presentationGroups.filter { !interaction.liveSessionIDs.contains($0.id) }
    }
    var defaultDetailGroup: AgentSessionGroup? {
        let live = liveGroups
        return live.count == 1 ? live.first : groups.count == 1 ? groups.first : nil
    }

    func showSessionList() { panel.prefersSessionList = true; panel.route = .sessions }
    func showApproval(_ id: String) {
        guard interaction.approvals.contains(where: { $0.id == id }) else { return }
        panel.route = .approval(id)
    }
    func setPanelEditing(_ editing: Bool) {
        panel.isEditing = editing
        if !editing { reconcilePanel() }
    }
    func setListInteracting(_ interacting: Bool) {
        panel.isListInteracting = interacting
        if !interacting { reconcilePanel() }
    }
    func leavePanel() { panel.isEditing = false; panel.isListInteracting = false; panel.prefersSessionList = false; panel.route = .sessions; reconcilePanel() }

    func refreshConnection() { (source as? AgentInteractiveSource)?.refreshConnection() }

    func draft(for id: AgentSessionID) -> AgentMessageDraft { messageDrafts[id] ?? AgentMessageDraft() }

    func setMessageDraft(_ text: String, for id: AgentSessionID) {
        var value = draft(for: id)
        guard value.text != text else { return }
        value.text = text; value.revision &+= 1
        if value.delivery != .sending && value.delivery != .uncertain { value.delivery = .ready; value.request = nil }
        messageDrafts[id] = value
    }

    func messageMode(for id: AgentSessionID) -> AgentMessageMode {
        groups.first(where: { $0.id == id })?.root.status.isTerminal == true ? .send : .steer
    }

    func canSendMessage(to id: AgentSessionID, mode: AgentMessageMode) -> Bool {
        let value = draft(for: id)
        guard isCodexActive, connection == .connected, source is AgentInteractiveSource,
              let group = groups.first(where: { $0.id == id }), group.root.classification == .userSession,
              mode == .send ? group.root.status.isTerminal : group.root.status == .running,
              interaction.primaryCapabilities[id]?.contains(mode.capability) == true,
              value.delivery != .sending, value.delivery != .uncertain,
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.text.utf8.count <= 32_000 else { return false }
        return true
    }

    func sendMessage(to id: AgentSessionID, mode: AgentMessageMode) {
        guard canSendMessage(to: id, mode: mode), let source = source as? AgentInteractiveSource,
              let group = groups.first(where: { $0.id == id }) else { return }
        var value = draft(for: id)
        let request = AgentMessageRequest(id: UUID(), sessionID: id, turnID: group.root.runID, mode: mode, text: value.text)
        let revision = value.revision, expected = generation
        value.request = request; value.delivery = .sending; messageDrafts[id] = value
        messageTasks[id] = Task { [weak self] in
            let result = await source.send(request)
            guard let self, self.generation == expected, self.messageDrafts[id]?.request?.id == request.id else { return }
            self.messageTasks.removeValue(forKey: id)
            var current = self.draft(for: id)
            current.delivery = [.accepted, .failed, .uncertain].contains(result) ? result : .uncertain
            if current.delivery == .accepted, current.revision == revision { current.text = ""; current.revision &+= 1 }
            self.messageDrafts[id] = current
        }
    }

    /// Explicit acknowledgement after inspecting the original chat, not a retry.
    func acknowledgeUncertainMessage(for id: AgentSessionID) {
        guard messageDrafts[id]?.delivery == .uncertain else { return }
        messageDrafts[id]?.delivery = .ready
        messageDrafts[id]?.request = nil
    }

    private func reconcilePanel() {
        if let request = panel.reconcile(groups: groups, interaction: interaction) { attentionRequestID = request }
    }

    func respondToApproval(_ id: String, decision: AgentHookDecision) {
        guard isEnabled, connection == .connected, let approval = interaction.approvals.first(where: { $0.id == id }),
              decision != .allow || approval.canAllow, decision != .deny || approval.canDeny else { return }
        (source as? AgentInteractiveSource)?.respond(id: id, decision: decision)
    }

    func canOpenSession(_ sessionID: AgentSessionID) -> Bool {
        guard isEnabled, connection == .connected, store.sessions[sessionID] != nil,
              let url = navigationTargets[sessionID]?.url else { return false }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        // Verified on the owner’s Mac: the current ChatGPT.app registers this
        // Codex bundle identifier. A different scheme handler is not trusted.
        return handlerBundleIdentifier(applicationURL) == "com.openai.codex"
    }

    func openSession(_ sessionID: AgentSessionID, openURL: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        guard canOpenSession(sessionID), let url = navigationTargets[sessionID]?.url else { return }
        openURL(url)
    }

    private func publishSnapshot() {
        let nextGroups = store.groups
        let nextAttentionCount = store.attentionCount
        guard groups != nextGroups || attentionCount != nextAttentionCount else { return }
        groups = nextGroups
        attentionCount = nextAttentionCount
        if let selectedSessionID, !nextGroups.contains(where: { $0.id == selectedSessionID }) { self.selectedSessionID = nil }
        reconcilePanel()
    }
}
