import Foundation

/// Pure state reduction. The module manager owns observation, cancellation and
/// lifecycle generations; disabled providers must not submit events here.
struct AgentSessionStore {
    private struct ReplayKey: Hashable {
        let session: AgentSessionID
        let runID: String?
        let eventID: String
    }
    private(set) var sessions: [AgentSessionID: AgentSessionSnapshot] = [:]
    private var replayOrder: [ReplayKey] = []
    private var replayKeys: Set<ReplayKey> = []
    private let maxSessions: Int
    private let maxReplayEvents: Int

    init(maxSessions: Int = 100, maxReplayEvents: Int = 500) {
        self.maxSessions = max(1, maxSessions)
        self.maxReplayEvents = max(1, maxReplayEvents)
    }

    @discardableResult
    mutating func ingest(_ event: AgentSessionEvent) -> Bool {
        guard !event.id.providerID.isEmpty, !event.id.sessionID.isEmpty,
              !event.eventID.isEmpty, event.sequence >= 0 else { return false }
        let key = ReplayKey(session: event.id, runID: event.runID, eventID: event.eventID)
        guard !replayKeys.contains(key) else { return false }
        if let existing = sessions[event.id] {
            guard event.sequence > existing.sequence else { return false }
            // A partial/unknown provenance update must not erase a verified
            // root or reclassify an internal item as ordinary activity.
            if event.classification == .unknown && existing.classification != .unknown {
                return false
            }
            // A run cannot resume after a terminal state. Starting another run
            // requires an explicit different, nonempty run ID.
            if existing.status.isTerminal {
                guard let runID = event.runID, !runID.isEmpty,
                      runID != existing.runID else { return false }
            }
        }
        // Never infer a parent from names or allow cross-provider parenting.
        guard event.parentID != event.id,
              event.parentID.map({ $0.providerID == event.id.providerID }) ?? true else { return false }
        sessions[event.id] = AgentSessionSnapshot(
            id: event.id, runID: event.runID, requestID: event.requestID,
            sequence: event.sequence, parentID: event.parentID,
            classification: event.classification, status: event.status,
            title: String(event.title.prefix(160)),
            summary: event.summary.map { String($0.prefix(500)) }, updatedAt: event.updatedAt
        )
        replayKeys.insert(key)
        replayOrder.append(key)
        while replayOrder.count > maxReplayEvents {
            replayKeys.remove(replayOrder.removeFirst())
        }
        if sessions.count > maxSessions {
            let oldest = sorted(Array(sessions.values)).last!
            sessions.removeValue(forKey: oldest.id)
        }
        return true
    }

    var rootSessions: [AgentSessionSnapshot] {
        sorted(sessions.values.filter { $0.classification == .userSession && $0.parentID == nil })
    }

    var groups: [AgentSessionGroup] {
        rootSessions.map { root in
            AgentSessionGroup(root: root, children: sorted(sessions.values.filter {
                $0.classification == .subagent && rootID(for: $0) == root.id
            }))
        }
    }

    var attentionCount: Int { groups.filter { $0.status.isWaiting }.count }

    /// Reconcile an authoritative successful source inventory. A failed poll
    /// must not call this method, because absence then is not deletion.
    mutating func retainSessions(_ ids: Set<AgentSessionID>) {
        sessions = sessions.filter { ids.contains($0.key) }
        replayOrder.removeAll { !ids.contains($0.session) }
        replayKeys = Set(replayOrder)
    }

    mutating func reset() {
        sessions.removeAll()
        replayOrder.removeAll()
        replayKeys.removeAll()
    }

    private func rootID(for snapshot: AgentSessionSnapshot) -> AgentSessionID? {
        var current = snapshot
        var visited: Set<AgentSessionID> = [snapshot.id]
        while let parentID = current.parentID {
            guard visited.insert(parentID).inserted, let parent = sessions[parentID] else { return nil }
            guard parent.classification == .subagent || parent.classification == .userSession else { return nil }
            current = parent
        }
        return current.classification == .userSession ? current.id : nil
    }

    private func sorted(_ values: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.id.providerID != $1.id.providerID { return $0.id.providerID < $1.id.providerID }
            return $0.id.sessionID < $1.id.sessionID
        }
    }
}
