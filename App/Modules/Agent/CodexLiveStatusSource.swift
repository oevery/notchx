import Foundation

/// Existing execution owners are primary. Hook fallback is explicit opt-in;
/// opening settings or enabling the provider never installs it.
@MainActor
final class CodexLiveStatusSource: AgentInteractiveSource {
    private let catalogue: CodexReadOnlyStatusSource
    private let server: AgentHookServer
    private let root: URL
    private var core = CodexAgentState()
    private var receive: (@MainActor (AgentSourceUpdate) -> Void)?
    private var generation = UUID()
    private var knownThreads: Set<String> = []
    private var verifiedRoots: Set<String> = []
    private var buffered: [AgentHookEnvelope] = []
    private var observers: [String: CodexTranscriptObserver] = [:]
    private var observerTasks: [String: Task<Void, Never>] = [:]
    private var observedTurns: [String: String] = [:]
    private let channels: [CodexPrimaryChannel]
    private let automation: CodexHookAutomation?
    private var primarySnapshots: [String: CodexPrimarySnapshot] = [:]
    private var candidates: [CodexPrimaryChannelKind: [String: CodexPrimarySnapshot]] = [:]
    private var threadDates: [String: Date] = [:]
    private var catalogueConnection = AgentSourceConnection.unconfigured
    private var hookFallbackEnabled = false
    private var fallbackGeneration = UUID()

    private var connection: AgentSourceConnection {
        if !core.snapshot.liveSessionIDs.isEmpty { return .connected }
        return catalogueConnection == .connected ? .disconnected : catalogueConnection
    }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
         socketPath: String = AgentUnixSocket.defaultPath,
         channels: [CodexPrimaryChannel]? = nil, automation: CodexHookAutomation? = nil) {
        self.root = root
        catalogue = CodexReadOnlyStatusSource(root: root)
        server = AgentHookServer(path: socketPath)
        self.channels = channels ?? [CodexDesktopStatusChannel(root: root), CodexDaemonChannel(root: root)]
        let shippingRoot = root.standardizedFileURL == CodexHookConfiguration.standard.root.standardizedFileURL
        let testHost = ProcessInfo.processInfo.environment["NOTCHX_UNIT_TEST_HOST"] == "1"
        self.automation = automation ?? (shippingRoot && !testHost ? .shared : nil)
    }

    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        stop()
        self.receive = receive
        let expected = generation
        for channel in channels {
            channel.start(threads: knownThreads) { [weak self] update in
                guard let self, self.generation == expected, self.receive != nil else { return }
                self.primaryUpdated(update)
            }
        }
        reconcileFallback()
        publish([])
        catalogue.start { [weak self] update in
            guard let self, self.generation == expected, self.receive != nil else { return }
            switch update {
            case .event(let metadata):
                self.knownThreads.insert(metadata.id.sessionID)
                self.threadDates[metadata.id.sessionID] = max(self.threadDates[metadata.id.sessionID] ?? .distantPast, metadata.updatedAt)
                if let normalized = self.core.register(metadata), self.core.snapshot.liveSessionIDs.contains(metadata.id) {
                    self.receive?(.event(normalized))
                }
            case .retainingSessions(let ids):
                self.knownThreads = Set(ids.map(\.sessionID)).union(self.verifiedRoots).union(self.primarySnapshots.keys)
                self.updatePrimaryThreads()
                self.receive?(.retainingSessions(self.core.retainCatalogue(ids)))
                let pending = self.buffered
                self.buffered.removeAll()
                for envelope in pending { self.process(envelope) }
            case .connection(let state):
                self.catalogueConnection = state
                self.receive?(.connection(self.connection))
                self.publish([])
            default: break
            }
        }
    }

    private func startFallback() {
        guard !core.snapshot.isListening else { return }
        let expected = generation, fallback = fallbackGeneration
        do {
            try server.start(receive: { [weak self] envelope in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expected, self.fallbackGeneration == fallback, self.receive != nil else { return }
                    self.received(envelope)
                }
            }, closed: { [weak self] id in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expected, self.fallbackGeneration == fallback, self.receive != nil else { return }
                    self.publish(self.core.closeRequest(id))
                }
            })
            core.setListening(true)
        } catch { core.setListening(false) }
    }

    func setHookFallbackEnabled(_ enabled: Bool) {
        guard hookFallbackEnabled != enabled else { return }
        hookFallbackEnabled = enabled
        if enabled { automation?.allowInstallation() }
        guard receive != nil else { return }
        reconcileFallback()
        receive?(.connection(connection))
        publish([])
    }

    private func stopFallback() {
        fallbackGeneration = UUID()
        server.stop()
        observerTasks.values.forEach { $0.cancel() }; observerTasks.removeAll()
        observers.values.forEach { $0.stop() }; observers.removeAll(); observedTurns.removeAll()
        buffered.removeAll(); verifiedRoots.removeAll()
        core.setLiveObserverCount(0)
        publish(core.stopHookActivity())
        receive?(.retainingSessions(core.retainedSessionIDs))
    }

    func stop() {
        generation = UUID()
        fallbackGeneration = UUID()
        channels.forEach { $0.stop() }
        automation?.configure(active: false)
        primarySnapshots.removeAll(); candidates.removeAll()
        threadDates.removeAll()
        catalogueConnection = .unconfigured
        observerTasks.values.forEach { $0.cancel() }; observerTasks.removeAll()
        observers.values.forEach { $0.stop() }; observers.removeAll(); observedTurns.removeAll()
        catalogue.stop()
        server.stop()
        receive = nil
        knownThreads.removeAll()
        verifiedRoots.removeAll()
        buffered.removeAll()
        core = CodexAgentState()
    }

    func respond(id: String, decision: AgentHookDecision) {
        guard receive != nil, [.allow, .deny, .deferToApp].contains(decision),
              let approval = core.snapshot.approvals.first(where: { $0.id == id }),
              decision != .allow || approval.canAllow, decision != .deny || approval.canDeny else { return }
        if let primary = primarySnapshots[approval.sessionID.sessionID],
           primary.approval?.id == id || primary.approvals.contains(where: { $0.id == id }),
           let channel = channels.first(where: { $0.kind == primary.kind }) {
            guard decision != .deferToApp, core.beginDecision(id) else { return }
            publish([])
            let expected = generation
            Task { [weak self] in
                let result = await channel.respond(approval: approval, decision: decision)
                guard let self, self.generation == expected, self.receive != nil else { return }
                self.core.finishNativeDecision(id, delivery: result)
                self.publish([])
            }
            return
        }
        guard core.beginDecision(id) else { return }
        publish([])
        server.respond(id: id, decision: decision)
    }

    func refreshConnection() {
        guard receive != nil else { return }
        catalogue.refresh()
        updatePrimaryThreads()
        reconcileFallback()
        automation?.refresh()
    }

    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery {
        guard receive != nil, request.sessionID == CodexAgentState.id(request.sessionID.sessionID),
              let primary = primarySnapshots[request.sessionID.sessionID],
              primary.classification == .userSession, primary.turnID == request.turnID,
              (request.mode == .send ? primary.status.isTerminal : primary.status == .running),
              primary.capabilities.contains(request.mode.capability),
              let channel = channels.first(where: { $0.kind == primary.kind }) else { return .failed }
        let expected = generation
        // Exactly one selected owner. An uncertain write must never be retried
        // on an alternate connection, even if coverage changes during delivery.
        let result = await channel.send(request)
        return generation == expected && receive != nil ? result : result == .failed ? .failed : .uncertain
    }

    private func updatePrimaryThreads() {
        for channel in channels {
            channel.updateThreads(Self.primaryThreadSelection(known: knownThreads, dates: threadDates,
                active: core.activeRootThreads, verified: verifiedRoots, limit: channel.kind == .desktop ? 32 : 80))
        }
    }

    static func primaryThreadSelection(known: Set<String>, dates: [String: Date], active: Set<String>,
                                       verified: Set<String>, limit: Int) -> Set<String> {
        Set(known.filter { UUID(uuidString: $0) != nil }.sorted {
            if active.contains($0) != active.contains($1) { return active.contains($0) }
            if verified.contains($0) != verified.contains($1) { return verified.contains($0) }
            let left = dates[$0] ?? .distantPast, right = dates[$1] ?? .distantPast
            return left == right ? $0 < $1 : left > right
        }.prefix(max(0, limit)))
    }

    private func primaryUpdated(_ update: CodexPrimaryChannelUpdate) {
        switch update {
        case .snapshot(let snapshot):
            guard AgentHookEnvelope.validID(snapshot.threadID),
                  snapshot.classification == .userSession || snapshot.classification == .subagent else { return }
            candidates[snapshot.kind, default: [:]][snapshot.threadID] = snapshot
            if primarySnapshots[snapshot.threadID]?.kind == .desktop && snapshot.kind != .desktop { return }
            applyPrimary(snapshot)
        case .unavailable(let kind, let threads):
            for thread in threads {
                candidates[kind]?.removeValue(forKey: thread)
                guard primarySnapshots[thread]?.kind == kind else { continue }
                let removed = primarySnapshots.removeValue(forKey: thread)
                let events = core.losePrimary(kind: kind, threads: [thread], preserveHookActivity: removed?.capabilities.contains(.lifecycle) != true)
                publish(events)
                if let alternate = candidates[kind == .desktop ? .daemon : .desktop]?[thread] { applyPrimary(alternate) }
            }
            receive?(.connection(connection))
        }
        reconcileFallback()
        publish([])
        receive?(.retainingSessions(core.retainedSessionIDs))
    }

    private func applyPrimary(_ snapshot: CodexPrimarySnapshot) {
        let value = snapshot
        if let previous = primarySnapshots[value.threadID], previous.kind == value.kind,
           let revision = value.revision, let old = previous.revision, revision <= old { return }
        var events = core.ingestPrimary(value)
        guard core.snapshot.primaryChannels[CodexAgentState.id(value.threadID)] == value.kind,
              value.turnID == nil || core.snapshot.contexts[CodexAgentState.id(value.threadID)]?.promptTurnID == value.turnID else { return }
        primarySnapshots[value.threadID] = value
        if value.classification == .userSession { events += core.setObservedChildren(value.observedChildren, parent: value.threadID) }
        if value.classification == .userSession { knownThreads.insert(value.threadID) }
        receive?(.connection(.connected))
        for id in core.invalidatedRequests { server.respond(id: id, decision: .deferToApp) }
        if value.capabilities.contains([.progress, .questions]) {
            observerTasks.removeValue(forKey: value.threadID)?.cancel()
            observers.removeValue(forKey: value.threadID)?.stop()
            observedTurns.removeValue(forKey: value.threadID)
        }
        pruneObservers()
        publish(events)
        receive?(.retainingSessions(core.retainedSessionIDs))
        receive?(.navigation(CodexAgentState.id(value.threadID), AgentVerifiedNavigationTarget(desktopThreadID: value.threadID)))
    }

    private func reconcileFallback() {
        guard receive != nil else { return }
        let snapshots = Array(primarySnapshots.values)
        let needed = CodexHookAutomation.needsFallback(snapshots: snapshots, activeThreads: core.activeRootThreads)
        if hookFallbackEnabled && needed { startFallback() }
        else if core.snapshot.isListening { stopFallback() }
        guard let automation else { return }
        let expected = generation
        automation.configure(active: true, fallbackEnabled: hookFallbackEnabled, snapshots: snapshots, activeThreads: core.activeRootThreads) { [weak self] state, events in
            guard let self, self.generation == expected, self.receive != nil else { return }
            self.core.setHookManagement(state, events: events)
            self.publish([])
        }
    }

    private func received(_ envelope: AgentHookEnvelope) {
        // Delivery acknowledgement is independent from UI/state processing.
        if envelope.event != "PermissionRequest" { server.respond(id: envelope.id, decision: .received) }
        if envelope.threadSource == "user", envelope.parentThreadID == nil, envelope.agentID == nil {
            verifiedRoots.insert(envelope.sessionID)
            if verifiedRoots.count > 100 { verifiedRoots = [envelope.sessionID] }
            knownThreads.insert(envelope.sessionID)
            threadDates[envelope.sessionID] = max(threadDates[envelope.sessionID] ?? .distantPast, envelope.sentAt)
            updatePrimaryThreads()
            receive?(.connection(.connected))
        }
        if !knownThreads.contains(envelope.sessionID), envelope.threadSource != "subagent",
           buffered.count < 16 {
            buffered.append(envelope)
            catalogue.refresh()
            return
        }
        process(envelope)
    }

    private func process(_ envelope: AgentHookEnvelope) {
        if let primary = primarySnapshots[envelope.sessionID], primary.turnID == envelope.turnID,
           (primary.capabilities.contains([.tools, .plans]) && ["PreToolUse", "PostToolUse"].contains(envelope.event)
            || primary.capabilities.contains(.messages) && envelope.event == "UserPromptSubmit") {
            core.recordCoveredHook(envelope)
            publish([])
            return
        }
        let events = core.ingest(envelope)
        pruneObservers()
        observe(envelope)
        for id in core.invalidatedRequests { server.respond(id: id, decision: .deferToApp) }
        if envelope.event == "PermissionRequest", !core.snapshot.approvals.contains(where: { $0.id == envelope.id }) {
            server.respond(id: envelope.id, decision: .deferToApp)
        }
        publish(events)
        updatePrimaryThreads()
        reconcileFallback()
        receive?(.retainingSessions(core.retainedSessionIDs))
        // Publish navigation after the session exists at the manager boundary.
        for event in events { receive?(.navigation(event.id, AgentVerifiedNavigationTarget(desktopThreadID: event.id.sessionID))) }
    }

    private func pruneObservers() {
        for (thread, turn) in observedTurns where !core.acceptsTranscript(thread: thread, turn: turn) {
            observerTasks.removeValue(forKey: thread)?.cancel()
            observers.removeValue(forKey: thread)?.stop(); observedTurns.removeValue(forKey: thread)
        }
        core.setLiveObserverCount(observers.values.filter(\.isActive).count)
    }

    private func observe(_ envelope: AgentHookEnvelope) {
        let thread = envelope.sessionID
        if primarySnapshots[thread]?.capabilities.contains([.progress, .questions]) == true { return }
        guard envelope.threadSource == "user", envelope.parentThreadID == nil,
              let path = envelope.transcriptPath, let turn = envelope.turnID,
              core.acceptsTranscript(thread: thread, turn: turn) else { return }
        if observedTurns[thread] == turn, observers[thread]?.isActive == true || observerTasks[thread] != nil { return }
        guard observedTurns[thread] != nil || observedTurns.count < 8 else { return }
        observers.removeValue(forKey: thread)?.stop(); observerTasks.removeValue(forKey: thread)?.cancel()
        observedTurns[thread] = turn
        let expected = generation, root = root
        observerTasks[thread] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try CodexTranscriptObserver(file: URL(fileURLWithPath: path), root: root, sessionID: thread, turnID: turn) { [weak self] signals in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expected, self.receive != nil, self.observedTurns[thread] == turn else { return }
                        let updates = self.core.ingestTranscript(signals, thread: thread, turn: turn)
                        for id in self.core.invalidatedRequests { self.server.respond(id: id, decision: .deferToApp) }
                        self.pruneObservers(); self.publish(updates)
                    }
                } }
            }.value
            guard !Task.isCancelled, let self, self.generation == expected, self.receive != nil, self.observedTurns[thread] == turn else {
                if case .success(let observer) = result { observer.stop() }; return
            }
            self.observerTasks[thread] = nil
            switch result {
            case .success(let observer): self.observers[thread] = observer
            case .failure: self.observedTurns[thread] = nil
            }
            self.pruneObservers(); self.publish([])
        }
    }

    private func publish(_ events: [AgentSessionEvent]) {
        for event in events { receive?(.event(event)) }
        var snapshot = core.snapshot
        snapshot.hookFallbackNeeded = CodexHookAutomation.needsFallback(snapshots: Array(primarySnapshots.values), activeThreads: core.activeRootThreads)
            && catalogueConnection != .unconfigured
        snapshot.suggestions = []
        receive?(.interaction(snapshot))
    }

}
