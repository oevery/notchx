import Foundation

struct AgentApproval: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: AgentSessionID
    let turnID: String
    let tool: String
    let command: String
    let reason: String?
    let expiresAt: Date
    var isSubmitting = false
    var canAllow = true
    var canDeny = true
    var denyEndsTurn = false
    var delivery = AgentMessageDelivery.ready
}

enum AgentMessageDelivery: String, Codable, Equatable, Sendable {
    case ready, sending, accepted, failed, uncertain
}

struct AgentSuggestion: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var target: AgentSessionID?
    let sourceTurnID: String?
    let title: String
    var text: String
    var delivery = AgentMessageDelivery.ready
    var targetTurnID: String? = nil
}

struct AgentInteractionSnapshot: Equatable, Sendable {
    var approvals: [AgentApproval] = []
    var suggestions: [AgentSuggestion] = []
    var liveSessionIDs: Set<AgentSessionID> = []
    var tools: [AgentSessionID: String] = [:]
    var isListening = false
    var receivedEvents = 0
    var rejectedEvents = 0
    var eventCounts: [String: Int] = [:]
    var rejectionCounts: [String: Int] = [:]
    var liveProgressUpdates = 0
    var liveObserverCount = 0
    var contexts: [AgentSessionID: AgentSessionContext] = [:]
    var primaryChannels: [AgentSessionID: CodexPrimaryChannelKind] = [:]
    var primaryCapabilities: [AgentSessionID: CodexPrimaryCapabilities] = [:]
    var hookManagement: CodexHookManagementState = .checking
    var suspendedHookEvents: Set<String> = []
    var hookFallbackNeeded = false
}

/// Pure, bounded Codex normalization. Catalogue metadata establishes candidate
/// user roots; events establish execution. No received timestamp is promoted to
/// an upstream sequence, and no title/cwd is used as session identity.
struct CodexAgentState {
    private struct Run {
        struct Tool {
            let id: String?
            let name: String?
            let detail: String?
        }
        var turn: String
        var status: AgentActivityStatus = .running
        var terminal = false
        var finishedTools: Set<String> = []
        var activeTools: [Tool] = []
        var tool: String? { activeTools.last?.name }
        var summary: String?
        var parent: AgentSessionID?
    }
    private var catalogue: [String: AgentSessionEvent] = [:]
    private var runs: [String: Run] = [:]
    private var retired: [String: [String]] = [:]
    private var closedTurns: [String: String] = [:]
    private var seenEvents: [String] = []
    private var hidden: Set<String> = []
    private var sequence: Int64 = 0
    private var primaryRevisions: [String: (CodexPrimaryChannelKind, Int64)] = [:]
    private var hookTurns: [String: String] = [:]
    private var primaryInputs: Set<String> = []
    private var primaryApprovalIDs: [String: Set<String>] = [:]
    private var observedChildren: [String: AgentSessionEvent] = [:]
    private(set) var snapshot = AgentInteractionSnapshot()
    private(set) var invalidatedRequests: [String] = []
    var retainedSessionIDs: Set<AgentSessionID> {
        Set(catalogue.values.map(\.id)).union(snapshot.liveSessionIDs)
            .union(observedChildren.values.map(\.id))
            .subtracting(hidden.map(Self.id)).subtracting(closedTurns.keys.map(Self.id))
    }

    mutating func setListening(_ listening: Bool) { snapshot.isListening = listening }
    mutating func stopHookActivity() -> [AgentSessionEvent] {
        snapshot.isListening = false
        let native = Set(primaryApprovalIDs.values.flatMap { $0 })
        snapshot.approvals.removeAll { !native.contains($0.id) }
        hookTurns.removeAll()
        var events: [AgentSessionEvent] = []
        for thread in Array(runs.keys) where snapshot.primaryChannels[Self.id(thread)] == nil {
            guard var run = runs[thread], !run.terminal else { continue }
            run.status = .unknown; run.activeTools = []; runs[thread] = run
            snapshot.tools.removeValue(forKey: Self.id(thread))
            snapshot.contexts[Self.id(thread)] = nil
            snapshot.liveSessionIDs.remove(Self.id(thread))
            events.append(event(thread: thread, run: run))
        }
        return events
    }
    var activeRootThreads: Set<String> { Set(runs.filter { !$0.value.terminal && $0.value.parent == nil }.keys) }
    mutating func recordCoveredHook(_ envelope: AgentHookEnvelope) {
        guard envelope.isValid, !seenEvents.contains(envelope.id) else { return }
        seenEvents.append(envelope.id)
        if seenEvents.count > 500 { seenEvents.removeFirst() }
        snapshot.receivedEvents += 1
        snapshot.eventCounts[envelope.event, default: 0] += 1
    }
    mutating func setHookManagement(_ state: CodexHookManagementState, events: Set<String>) {
        snapshot.hookManagement = state; snapshot.suspendedHookEvents = events
    }

    mutating func setObservedChildren(_ values: [CodexPrimarySnapshot], parent: String) -> [AgentSessionEvent] {
        let accepted = values.prefix(32).filter {
            $0.parentThreadID == parent && $0.classification == .subagent && UUID(uuidString: $0.threadID) != nil
                && $0.threadID != parent && snapshot.primaryChannels[Self.id($0.threadID)] == nil
        }
        let retained = Set(accepted.map(\.threadID))
        for (thread, value) in observedChildren where value.parentID == Self.id(parent) && !retained.contains(thread) {
            observedChildren.removeValue(forKey: thread)
            if snapshot.primaryChannels[Self.id(thread)] == nil { snapshot.contexts.removeValue(forKey: Self.id(thread)) }
        }
        return accepted.map { child in
            sequence += 1
            let event = AgentSessionEvent(id: Self.id(child.threadID), runID: nil, requestID: nil, eventID: UUID().uuidString,
                sequence: sequence, parentID: Self.id(parent), classification: .subagent, status: .unknown, title: child.title,
                summary: nil, updatedAt: child.updatedAt ?? .distantPast)
            observedChildren[child.threadID] = event; snapshot.contexts[event.id] = child.context
            return event
        }
    }

    /// Primary snapshots are authoritative state, not invented Hook receipts.
    /// Their source revision is guarded separately from normalized host events.
    mutating func ingestPrimary(_ value: CodexPrimarySnapshot) -> [AgentSessionEvent] {
        invalidatedRequests = []
        guard AgentHookEnvelope.validID(value.threadID),
              value.turnID.map(AgentHookEnvelope.validID) != false,
              value.parentThreadID.map(AgentHookEnvelope.validID) != false,
              value.parentThreadID != value.threadID,
              value.classification == .userSession || value.classification == .subagent else { return [] }
        if let parent = value.parentThreadID, hasTerminalAncestor(parent) { return [] }
        if let revision = value.revision, let prior = primaryRevisions[value.threadID],
           prior.0 == value.kind, revision <= prior.1 { return [] }
        if let turn = value.turnID, (retired[value.threadID] ?? []).contains(turn) { return [] }
        if let closed = closedTurns[value.threadID], closed == value.turnID { return [] }
        if let current = runs[value.threadID], let turn = value.turnID {
            if current.turn != turn {
                if let previous = snapshot.contexts[Self.id(value.threadID)]?.startedAt {
                    if let incoming = value.context.startedAt {
                        guard incoming >= previous else { return [] }
                    } else if !value.capabilities.contains(.lifecycle) { return [] }
                }
            } else if current.terminal && !value.status.isTerminal { return [] }
        }
        if let revision = value.revision { primaryRevisions[value.threadID] = (value.kind, revision) }
        let id = Self.id(value.threadID)
        snapshot.primaryChannels[id] = value.kind
        snapshot.primaryCapabilities[id] = value.capabilities
        if catalogue[value.threadID] == nil, value.classification == .userSession {
            catalogue[value.threadID] = AgentSessionEvent(id: id, runID: nil, requestID: nil,
                eventID: UUID().uuidString, sequence: 0, parentID: nil, classification: .userSession,
                status: .unknown, title: value.title.isEmpty ? value.threadID : String(value.title.prefix(160)), summary: nil,
                updatedAt: value.updatedAt ?? .distantPast)
            boundCatalogue()
        }
        guard let turn = value.turnID else {
            var context = snapshot.contexts[id] ?? AgentSessionContext()
            context.cwd = value.context.cwd ?? context.cwd
            context.branch = value.context.branch ?? context.branch
            context.model = value.context.model ?? context.model
            snapshot.contexts[id] = context
            return []
        }
        if let current = runs[value.threadID], current.turn != turn {
            // A stale initial snapshot cannot undo newer Hook-established input.
            if let previous = snapshot.contexts[id]?.startedAt,
               let incoming = value.context.startedAt, incoming < previous { return [] }
            retired[value.threadID, default: []].append(current.turn)
            retired[value.threadID] = Array(retired[value.threadID, default: []].suffix(16))
            invalidate(thread: value.threadID)
            closeDescendants(of: value.threadID)
            snapshot.contexts[id] = nil
        } else if let current = runs[value.threadID], current.terminal, !value.status.isTerminal { return [] }
        closedTurns.removeValue(forKey: value.threadID)
        var context = value.context
        let previous = snapshot.contexts[id]
        context.cwd = context.cwd ?? previous?.cwd
        context.branch = context.branch ?? previous?.branch
        context.model = context.model ?? previous?.model
        context.prompt = AgentMessagePreview.userMessage(context.prompt) ?? previous?.prompt
        context.promptTurnID = turn
        context.startedAt = context.startedAt ?? previous?.startedAt
        if !value.capabilities.contains(.messages), hookTurns[value.threadID] == turn {
            context.prompt = previous?.prompt
        }
        if !value.capabilities.contains(.questions) {
            if context.pendingInput != nil { primaryInputs.insert(value.threadID) }
            else if primaryInputs.contains(value.threadID) {
                if value.status == .waitingInput { context.pendingInput = previous?.pendingInput }
                else { primaryInputs.remove(value.threadID) }
            } else { context.pendingInput = previous?.pendingInput }
        }
        if !value.capabilities.contains(.progress) { context.progressText = previous?.progressText }
        if let oldDate = previous?.activityAt, let date = context.activityAt, date < oldDate {
            context.latestActivity = previous?.latestActivity; context.activityAt = oldDate
        }
        var run = Run(turn: turn, status: value.status, parent: value.parentThreadID.map(Self.id))
        run.terminal = value.status.isTerminal
        if let tool = value.activeToolName { run.activeTools = [Run.Tool(id: value.activeToolID, name: tool, detail: context.toolDetail)] }
        if !value.capabilities.contains(.tools), hookTurns[value.threadID] == turn, let previousRun = runs[value.threadID] {
            run.activeTools = previousRun.activeTools
            run.finishedTools = previousRun.finishedTools
            context.toolDetail = previous?.toolDetail
            context.lastCompletedTool = previous?.lastCompletedTool
            if case .progress = context.latestActivity, value.capabilities.contains(.progress),
               let incoming = context.activityAt, incoming >= (previous?.activityAt ?? .distantPast) {
                // New public commentary can supersede an older Hook preview
                // without claiming complete native tool lifecycle coverage.
            } else {
                context.latestActivity = previous?.latestActivity
                context.activityAt = previous?.activityAt
            }
        }
        if run.terminal {
            invalidate(thread: value.threadID)
            closeDescendants(of: value.threadID)
            context.pendingInput = nil; context.latestActivity = nil; context.activityAt = nil
            context.lastCompletedTool = nil; context.progressText = nil; run.activeTools = []
            primaryInputs.remove(value.threadID)
        }
        let nativeApprovals = (value.approvals + (value.approval.map { [$0] } ?? [])).filter {
            $0.sessionID == id && $0.turnID == turn && $0.expiresAt > Date()
        }
        let oldNative = primaryApprovalIDs[value.threadID] ?? []
        let nextNative = Set((run.terminal ? [] : nativeApprovals).map(\.id))
        snapshot.approvals.removeAll { oldNative.contains($0.id) && !nextNative.contains($0.id) }
        primaryApprovalIDs[value.threadID] = nextNative
        if value.capabilities.contains(.approvals), !run.terminal {
            for approval in nativeApprovals.prefix(16) where !snapshot.approvals.contains(where: { $0.id == approval.id }) {
                snapshot.approvals.append(approval)
            }
        }
        if snapshot.approvals.contains(where: { $0.sessionID == id }) { run.status = .waitingApproval }
        runs[value.threadID] = run; snapshot.contexts[id] = context
        snapshot.liveSessionIDs.insert(id); snapshot.tools[id] = run.tool
        return [event(thread: value.threadID, run: run, updatedAt: value.updatedAt ?? context.startedAt ?? catalogue[value.threadID]?.updatedAt)]
    }

    mutating func losePrimary(kind: CodexPrimaryChannelKind, threads: Set<String>, preserveHookActivity: Bool = false) -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = []
        for thread in threads where snapshot.primaryChannels[Self.id(thread)] == kind {
            snapshot.primaryChannels.removeValue(forKey: Self.id(thread))
            snapshot.primaryCapabilities.removeValue(forKey: Self.id(thread))
            primaryRevisions.removeValue(forKey: thread)
            let native = primaryApprovalIDs.removeValue(forKey: thread) ?? []
            snapshot.approvals.removeAll { native.contains($0.id) }
            _ = setObservedChildren([], parent: thread)
            // Disconnection is not task completion. Keep metadata and draft,
            // but revoke live progress and any primary response handles.
            guard var run = runs[thread], !run.terminal else { continue }
            if preserveHookActivity, hookTurns[thread] == run.turn { continue }
            run.status = .unknown; run.activeTools = []; runs[thread] = run
            snapshot.contexts[Self.id(thread)]?.pendingInput = nil
            primaryInputs.remove(thread)
            snapshot.contexts[Self.id(thread)]?.latestActivity = nil
            snapshot.tools.removeValue(forKey: Self.id(thread))
            events.append(event(thread: thread, run: run))
        }
        return events
    }
    mutating func setLiveObserverCount(_ count: Int) { snapshot.liveObserverCount = count }
    func acceptsTranscript(thread: String, turn: String) -> Bool {
        guard let run = runs[thread] else { return false }
        return run.turn == turn && !run.terminal && closedTurns[thread] == nil
    }

    mutating func ingestTranscript(_ signals: [CodexTranscriptSignal], thread: String, turn: String) -> [AgentSessionEvent] {
        invalidatedRequests = []
        guard acceptsTranscript(thread: thread, turn: turn), var run = runs[thread],
              var context = snapshot.contexts[Self.id(thread)] else { return [] }
        for signal in signals {
            guard !run.terminal else { break }
            switch signal {
            case .progress(let text, let date):
                if let preview = AgentMessagePreview.line(text) {
                    context.progressText = preview
                    context.recordActivity(.progress(preview), at: date)
                }
            case .question(let question):
                guard !primaryInputs.contains(thread) else { continue }
                context.pendingInput = question; run.status = .waitingInput
            case .answered:
                guard !primaryInputs.contains(thread) else { continue }
                context.pendingInput = nil
                if run.status == .waitingInput { run.status = .running }
            case .ended, .cancelled:
                context.pendingInput = nil; context.progressText = nil; context.lastCompletedTool = nil
                context.latestActivity = nil; context.activityAt = nil
                run.activeTools = []; run.terminal = true; run.status = signal == .cancelled ? .cancelled : .completed
                invalidate(thread: thread); closeDescendants(of: thread)
            }
            snapshot.liveProgressUpdates += 1
        }
        if snapshot.approvals.contains(where: { $0.sessionID == Self.id(thread) }) { run.status = .waitingApproval }
        runs[thread] = run; snapshot.contexts[Self.id(thread)] = context; snapshot.tools[Self.id(thread)] = run.tool
        return [event(thread: thread, run: run)]
    }

    private mutating func reject(_ reason: String) -> [AgentSessionEvent] {
        snapshot.rejectedEvents += 1; snapshot.rejectionCounts[reason, default: 0] += 1
        return []
    }
    static func id(_ thread: String) -> AgentSessionID {
        AgentSessionID(providerID: "codex.local.catalog", sessionID: thread)
    }

    mutating func register(_ metadata: AgentSessionEvent) -> AgentSessionEvent? {
        catalogue[metadata.id.sessionID] = metadata
        boundCatalogue()
        guard !hidden.contains(metadata.id.sessionID), closedTurns[metadata.id.sessionID] == nil else { return nil }
        if let run = runs[metadata.id.sessionID] { return event(thread: metadata.id.sessionID, run: run) }
        sequence += 1
        return AgentSessionEvent(id: metadata.id, runID: nil, requestID: nil, eventID: UUID().uuidString,
            sequence: sequence, parentID: nil, classification: .userSession, status: .unknown,
            title: metadata.title, summary: nil, updatedAt: metadata.updatedAt)
    }

    mutating func retainCatalogue(_ ids: Set<AgentSessionID>) -> Set<AgentSessionID> {
        catalogue = catalogue.filter { ids.contains($0.value.id) }
        return retainedSessionIDs
    }

    mutating func ingest(_ envelope: AgentHookEnvelope, now: Date = Date()) -> [AgentSessionEvent] {
        invalidatedRequests = []
        guard envelope.isValid else { return reject("invalid") }
        guard !seenEvents.contains(envelope.id) else { return reject("duplicate") }
        guard abs(envelope.sentAt.timeIntervalSince(now)) < 180 else { return reject("expired") }
        seenEvents.append(envelope.id)
        if seenEvents.count > 500 { seenEvents.removeFirst() }
        snapshot.receivedEvents += 1
        snapshot.eventCounts[envelope.event, default: 0] += 1
        // Classify the complete envelope BEFORE touching visible session state.
        if let suggestions = suggestions(in: envelope) {
            for suggestion in suggestions where !snapshot.suggestions.contains(where: {
                $0.target == suggestion.target && $0.sourceTurnID == suggestion.sourceTurnID && $0.text == suggestion.text
            }) { snapshot.suggestions.append(suggestion) }
            snapshot.suggestions = Array(snapshot.suggestions.suffix(40))
            return []
        }
        if envelope.threadSource == "unverified" { return reject("identity") }
        if let source = envelope.threadSource, source != "user" && source != "subagent" {
            invalidate(thread: envelope.sessionID)
            snapshot.liveSessionIDs.remove(Self.id(envelope.sessionID))
            snapshot.tools.removeValue(forKey: Self.id(envelope.sessionID))
            snapshot.contexts.removeValue(forKey: Self.id(envelope.sessionID))
            runs.removeValue(forKey: envelope.sessionID)
            retired.removeValue(forKey: envelope.sessionID)
            catalogue.removeValue(forKey: envelope.sessionID)
            hidden.insert(envelope.sessionID)
            if hidden.count > 100 { hidden = [envelope.sessionID] }
            return []
        }
        // Parent-side spawn notifications are not child activity or new roots.
        guard envelope.event != "SubagentStart", envelope.event != "SubagentStop" else { return [] }
        let isChild = envelope.threadSource == "subagent" || envelope.parentThreadID != nil
        let parent = envelope.parentThreadID.map(Self.id)
        if let parent, hasTerminalAncestor(parent.sessionID) { return [] }
        if let closed = closedTurns[envelope.sessionID] {
            guard envelope.event == "UserPromptSubmit", let turn = envelope.turnID, turn != closed else { return reject("closed") }
            closedTurns.removeValue(forKey: envelope.sessionID)
        }
        if catalogue[envelope.sessionID] == nil, envelope.threadSource == "user", !isChild {
            catalogue[envelope.sessionID] = AgentSessionEvent(id: Self.id(envelope.sessionID), runID: nil,
                requestID: nil, eventID: envelope.id, sequence: 0, parentID: nil, classification: .userSession,
                status: .unknown, title: envelope.title ?? envelope.sessionID, summary: nil, updatedAt: now)
            boundCatalogue()
        }
        guard catalogue[envelope.sessionID] != nil || (isChild && parent.map { catalogue[$0.sessionID] != nil || runs[$0.sessionID] != nil } == true),
              !hidden.contains(envelope.sessionID) else { return reject("unknown") }
        guard envelope.event != "SessionStart", envelope.event != "SessionEnd" else {
            if envelope.event == "SessionEnd" { return disconnect(thread: envelope.sessionID) }
            return []
        }
        guard let turn = envelope.turnID, !turn.isEmpty else { return reject("missingTurn") }
        guard !(retired[envelope.sessionID] ?? []).contains(turn) else { return reject("oldTurn") }
        if let current = runs[envelope.sessionID], current.turn != turn {
            // Only explicit user input establishes a replacement run. A delayed
            // tool/Stop for an unknown older run cannot replace the current one.
            guard envelope.event == "UserPromptSubmit" else { return reject("oldTurn") }
            retired[envelope.sessionID, default: []].append(current.turn)
            retired[envelope.sessionID] = Array(retired[envelope.sessionID, default: []].suffix(16))
            invalidate(thread: envelope.sessionID)
            closeDescendants(of: envelope.sessionID)
            runs[envelope.sessionID] = nil
        }
        let startsNewRun = runs[envelope.sessionID] == nil
        var run = runs[envelope.sessionID] ?? Run(turn: turn, parent: parent)
        guard !run.terminal else { return reject("closed") }
        if envelope.event == "PreToolUse", let toolID = envelope.toolID, run.finishedTools.contains(toolID) { return reject("finishedTool") }
        if envelope.event == "PostToolUse", let toolID = envelope.toolID, run.finishedTools.contains(toolID) { return reject("finishedTool") }
        let session = Self.id(envelope.sessionID)
        var context = snapshot.contexts[session] ?? AgentSessionContext()
        if let cwd = envelope.cwd { context.cwd = cwd }
        if let branch = envelope.branch { context.branch = branch }
        if let model = envelope.model { context.model = model }
        if envelope.event == "UserPromptSubmit" {
            context.prompt = AgentMessagePreview.userMessage(envelope.userPrompt)
            context.promptTurnID = turn
            if startsNewRun || context.startedAt == nil { context.startedAt = envelope.sentAt }
            context.pendingInput = nil
            if startsNewRun {
                context.plan = []; context.toolDetail = nil; context.lastCompletedTool = nil; context.progressText = nil
                context.latestActivity = nil; context.activityAt = nil
            }
        }
        if startsNewRun, context.startedAt == nil { context.startedAt = envelope.sentAt }
        if ["PreToolUse", "PostToolUse"].contains(envelope.event), let plan = envelope.plan { context.plan = plan }
        switch envelope.event {
        case "UserPromptSubmit":
            run.status = .running
        case "PreToolUse":
            if let id = envelope.toolID { run.activeTools.removeAll { $0.id == id } }
            run.activeTools.append(Run.Tool(id: envelope.toolID, name: envelope.toolName, detail: envelope.toolDetail))
            run.activeTools = Array(run.activeTools.suffix(32))
            context.lastCompletedTool = nil
            // The hook timestamp and transcript record timestamp share the
            // same local clock. Receipt order is not an upstream sequence.
            if let name = envelope.toolName { context.recordActivity(.tool(name: name, detail: envelope.toolDetail), at: envelope.sentAt) }
            run.status = context.pendingInput == nil ? .running : .waitingInput
        case "PostToolUse":
            let index: Int?
            if let id = envelope.toolID { index = run.activeTools.lastIndex { $0.id == id } }
            else { index = run.activeTools.lastIndex { envelope.toolName == nil || $0.name == envelope.toolName } }
            let finished = index.map { run.activeTools.remove(at: $0) }
            if let name = finished?.name ?? envelope.toolName {
                let detail = finished?.detail ?? envelope.toolDetail
                let outcome = envelope.toolOutcome ?? .completed
                context.lastCompletedTool = AgentCompletedTool(name: name, detail: detail, finishedAt: envelope.sentAt, outcome: outcome)
                context.recordActivity(.completedTool(name: name, detail: detail, outcome: outcome), at: envelope.sentAt)
            }
            if let toolID = envelope.toolID {
                run.finishedTools.insert(toolID)
                if run.finishedTools.count > 200 { run.finishedTools = [toolID] }
            }
            invalidate(thread: envelope.sessionID, command: envelope.command)
            run.status = context.pendingInput == nil ? .running : .waitingInput
        case "PermissionRequest":
            // Respect Auto Review. Only an explicit human reviewer, verified in
            // this turn's bounded metadata, can delegate a decision to the island.
            run.status = envelope.reviewer == nil || envelope.permissionMode == "bypassPermissions" ? .unknown : .running
            if envelope.reviewer == "user", envelope.permissionMode != "bypassPermissions" {
                run.status = .waitingApproval
                if let command = envelope.command, !command.isEmpty, snapshot.approvals.count < 16 {
                    snapshot.approvals.append(AgentApproval(id: envelope.id, sessionID: Self.id(envelope.sessionID),
                        turnID: turn, tool: envelope.toolName ?? "", command: command, reason: envelope.reason,
                        expiresAt: now.addingTimeInterval(110)))
                }
            }
        case "Stop":
            context.pendingInput = nil; context.progressText = nil
            invalidate(thread: envelope.sessionID)
            closeDescendants(of: envelope.sessionID)
            run.activeTools = []
            context.lastCompletedTool = nil
            context.latestActivity = nil; context.activityAt = nil
            run.summary = envelope.message
            run.status = .completed
            run.terminal = true
        case "Interrupt":
            context.pendingInput = nil; context.progressText = nil
            invalidate(thread: envelope.sessionID)
            closeDescendants(of: envelope.sessionID)
            run.status = .cancelled
            run.terminal = true
            run.activeTools = []
            context.lastCompletedTool = nil
            context.latestActivity = nil; context.activityAt = nil
        case "PreCompact", "PostCompact": break
        default: return []
        }
        if snapshot.approvals.contains(where: { $0.sessionID == Self.id(envelope.sessionID) }) { run.status = .waitingApproval }
        context.toolDetail = run.activeTools.last?.detail
        snapshot.contexts[session] = context
        runs[envelope.sessionID] = run
        hookTurns[envelope.sessionID] = turn
        snapshot.liveSessionIDs.insert(Self.id(envelope.sessionID))
        snapshot.tools[Self.id(envelope.sessionID)] = run.tool
        if runs.count > 100, let oldest = runs.keys.sorted().first(where: { $0 != envelope.sessionID }) {
            runs.removeValue(forKey: oldest)
            retired.removeValue(forKey: oldest)
            snapshot.liveSessionIDs.remove(Self.id(oldest))
            snapshot.tools.removeValue(forKey: Self.id(oldest))
            snapshot.contexts.removeValue(forKey: Self.id(oldest))
            invalidate(thread: oldest)
        }
        return [event(thread: envelope.sessionID, run: run)]
    }

    mutating func beginDecision(_ id: String, now: Date = Date()) -> Bool {
        guard let index = snapshot.approvals.firstIndex(where: { $0.id == id }),
              snapshot.approvals[index].expiresAt > now, !snapshot.approvals[index].isSubmitting else { return false }
        snapshot.approvals[index].isSubmitting = true
        snapshot.approvals[index].delivery = .sending
        return true
    }

    mutating func finishNativeDecision(_ id: String, delivery: AgentMessageDelivery) {
        guard let index = snapshot.approvals.firstIndex(where: { $0.id == id }) else { return }
        snapshot.approvals[index].delivery = delivery
        snapshot.approvals[index].isSubmitting = delivery != .failed
    }

    mutating func closeRequest(_ id: String) -> [AgentSessionEvent] {
        guard let request = snapshot.approvals.first(where: { $0.id == id }) else { return [] }
        snapshot.approvals.removeAll { $0.id == id }
        guard var run = runs[request.sessionID.sessionID], !run.terminal,
              !snapshot.approvals.contains(where: { $0.sessionID == request.sessionID }) else { return [] }
        run.status = .unknown // Sending a decision is not proof that Codex applied it.
        runs[request.sessionID.sessionID] = run
        return [event(thread: request.sessionID.sessionID, run: run)]
    }

    mutating func setDelivery(_ delivery: AgentMessageDelivery, suggestionID: String) {
        guard let index = snapshot.suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        snapshot.suggestions[index].delivery = delivery
    }

    mutating func editSuggestion(_ id: String, text: String, target: AgentSessionID?) {
        guard let index = snapshot.suggestions.firstIndex(where: { $0.id == id }),
              snapshot.suggestions[index].delivery == .ready || snapshot.suggestions[index].delivery == .failed else { return }
        snapshot.suggestions[index].text = String(text.prefix(8000))
        snapshot.suggestions[index].target = target
    }

    private mutating func invalidate(thread: String, command: String? = nil) {
        let removed = snapshot.approvals.filter { $0.sessionID.sessionID == thread && (command == nil || $0.command == command) }
        invalidatedRequests.append(contentsOf: removed.map(\.id))
        let ids = Set(removed.map(\.id))
        snapshot.approvals.removeAll { ids.contains($0.id) }
    }

    private mutating func boundCatalogue() {
        guard catalogue.count > 140, let oldest = catalogue.values.sorted(by: {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.sessionID < $1.id.sessionID
        }).first else { return }
        catalogue.removeValue(forKey: oldest.id.sessionID)
    }

    private mutating func disconnect(thread: String) -> [AgentSessionEvent] {
        for item in [thread] + descendants(of: thread) {
            invalidate(thread: item)
            closedTurns[item] = runs[item]?.turn ?? ""
            runs.removeValue(forKey: item)
            catalogue.removeValue(forKey: item)
            snapshot.liveSessionIDs.remove(Self.id(item))
            snapshot.tools.removeValue(forKey: Self.id(item))
            snapshot.contexts.removeValue(forKey: Self.id(item))
            snapshot.primaryChannels.removeValue(forKey: Self.id(item))
            snapshot.primaryCapabilities.removeValue(forKey: Self.id(item))
            primaryRevisions.removeValue(forKey: item)
            hookTurns.removeValue(forKey: item)
            primaryInputs.remove(item)
        }
        if closedTurns.count > 100 {
            for id in closedTurns.keys.sorted().prefix(closedTurns.count - 100) {
                closedTurns.removeValue(forKey: id)
                retired.removeValue(forKey: id)
            }
        }
        return []
    }

    private mutating func closeDescendants(of thread: String) {
        // Remove child inventory as well as its response handles. Otherwise a
        // parent's next turn can inherit attention from a finished child.
        for child in descendants(of: thread) { _ = disconnect(thread: child) }
    }

    private func hasTerminalAncestor(_ thread: String) -> Bool {
        var current: String? = thread, visited: Set<String> = []
        while let id = current {
            guard visited.insert(id).inserted, closedTurns[id] == nil else { return true }
            if runs[id]?.terminal == true { return true }
            current = runs[id]?.parent?.sessionID
        }
        return false
    }

    private func descendants(of root: String) -> [String] {
        var found: Set<String> = [root], result: [String] = [], pending = [root]
        while let parent = pending.popLast() {
            for (thread, run) in runs where run.parent?.sessionID == parent && found.insert(thread).inserted {
                result.append(thread)
                pending.append(thread)
            }
        }
        return result
    }

    private mutating func event(thread: String, run: Run, updatedAt: Date? = nil) -> AgentSessionEvent {
        sequence += 1
        return AgentSessionEvent(id: Self.id(thread), runID: run.turn, requestID: nil,
            eventID: UUID().uuidString, sequence: sequence, parentID: run.parent,
            classification: run.parent == nil ? .userSession : .subagent, status: run.status,
            title: catalogue[thread]?.title ?? thread, summary: run.summary, updatedAt: updatedAt ?? Date())
    }

    private func suggestions(in envelope: AgentHookEnvelope) -> [AgentSuggestion]? {
        guard envelope.event == "Stop", let text = envelope.message, let bytes = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["suggestions"], let entries = object["suggestions"] as? [[String: Any]] else { return nil }
        return entries.prefix(8).compactMap { entry in
            guard let title = entry["title"] as? String,
                  let prompt = (entry["prompt"] ?? entry["description"]) as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let explicit = entry["thread_id"] as? String
            let target: AgentSessionID?
            if let explicit { target = catalogue[explicit]?.id }
            else { target = catalogue[envelope.sessionID]?.id }
            return AgentSuggestion(id: UUID().uuidString, target: target, sourceTurnID: envelope.turnID,
                title: String(title.prefix(160)), text: String(prompt.prefix(8000)),
                targetTurnID: target.flatMap { runs[$0.sessionID]?.turn })
        }
    }
}
