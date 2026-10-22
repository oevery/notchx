import Foundation

/// Provider health is separate from activity. An empty list never means connected.
enum AgentSourceConnection: Equatable, Sendable {
    case unconfigured
    case disconnected
    case connected
    case permissionDenied
    case unsupportedSchema
}

/// Constructed only from a verified catalogue or exact hook transcript thread ID.
/// Metadata does not establish Desktop creation or current execution.
/// Never derive this ID from a title, cwd or PID; the manager pins the handler.
struct AgentVerifiedNavigationTarget: Equatable {
    let desktopThreadID: String

    var url: URL? {
        guard !desktopThreadID.isEmpty,
              desktopThreadID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0)
              }) else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/" + desktopThreadID
        return components.url
    }
}

enum AgentSourceUpdate {
    case connection(AgentSourceConnection)
    case event(AgentSessionEvent)
    case retainingSessions(Set<AgentSessionID>)
    case navigation(AgentSessionID, AgentVerifiedNavigationTarget)
    case interaction(AgentInteractionSnapshot)
}

/// Compiled-in status sources own their cancellable I/O, but use the host's
/// scheduler if polling is needed. stop() must synchronously release observers
/// and cancel pending tasks. The manager additionally rejects late callbacks.
@MainActor
protocol AgentStatusSource: AnyObject {
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void)
    func stop()
}

@MainActor
protocol AgentInteractiveSource: AgentStatusSource {
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery
    func respond(id: String, decision: AgentHookDecision)
    func refreshConnection()
    func setHookFallbackEnabled(_ enabled: Bool)
}

extension AgentInteractiveSource {
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery { .failed }
    func refreshConnection() {}
    func setHookFallbackEnabled(_ enabled: Bool) {}
}
