import Foundation

enum CodexPrimaryChannelKind: String, Sendable { case desktop, daemon }

enum CodexHookManagementState: String, Equatable, Sendable {
    case checking, ready, suspended, waitingForTrust, waitingForRefresh, unavailable, off
}

/// Coverage is earned per loaded thread, never from a socket or app version.
struct CodexPrimaryCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: Int
    static let lifecycle = Self(rawValue: 1 << 0)
    static let tools = Self(rawValue: 1 << 1)
    static let messages = Self(rawValue: 1 << 2)
    static let progress = Self(rawValue: 1 << 3)
    static let plans = Self(rawValue: 1 << 4)
    static let questions = Self(rawValue: 1 << 5)
    static let approvals = Self(rawValue: 1 << 6)
    static let children = Self(rawValue: 1 << 7)
    static let send = Self(rawValue: 1 << 8)
    static let steer = Self(rawValue: 1 << 9)
    static let queue = Self(rawValue: 1 << 10)
}

extension AgentMessageMode {
    var capability: CodexPrimaryCapabilities {
        switch self { case .send: return .send; case .steer: return .steer; case .queue: return .queue }
    }
}

struct CodexPrimarySnapshot: Sendable {
    let kind: CodexPrimaryChannelKind
    let threadID: String
    var turnID: String?
    var parentThreadID: String?
    var title = ""
    var classification: AgentSourceClassification = .unknown
    var status: AgentActivityStatus = .unknown
    var context = AgentSessionContext()
    var activeToolName: String?
    var activeToolID: String?
    var approval: AgentApproval?
    var approvals: [AgentApproval] = []
    var capabilities: CodexPrimaryCapabilities = []
    /// Source revision/timestamp only; never label historical data as new work.
    var revision: Int64?
    var updatedAt: Date?
    var ownerID: String?
    var observedChildren: [CodexPrimarySnapshot] = []
}

enum CodexPrimaryChannelUpdate: Sendable {
    case snapshot(CodexPrimarySnapshot)
    case unavailable(CodexPrimaryChannelKind, Set<String>)
}

@MainActor
protocol CodexPrimaryChannel: AnyObject {
    var kind: CodexPrimaryChannelKind { get }
    func start(threads: Set<String>, receive: @escaping @MainActor (CodexPrimaryChannelUpdate) -> Void)
    func updateThreads(_ threads: Set<String>)
    func stop()
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery
    func respond(approval: AgentApproval, decision: AgentHookDecision) async -> AgentMessageDelivery
    func respondToInput(_ response: AgentInputResponse) async -> AgentMessageDelivery
}

extension CodexPrimaryChannel {
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery { .failed }
    func respond(approval: AgentApproval, decision: AgentHookDecision) async -> AgentMessageDelivery { .failed }
    func respondToInput(_ response: AgentInputResponse) async -> AgentMessageDelivery { .failed }
}
