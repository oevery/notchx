import Foundation

/// Provider-local identifiers are never interchangeable with run or request IDs.
struct AgentSessionID: Hashable, Codable, Sendable {
    let providerID: String
    // Actual provider thread identity, including for child threads. Codex's
    // root/session_id metadata must not replace its actual thread `id` here.
    let sessionID: String
}

enum AgentActivityStatus: String, CaseIterable, Sendable {
    case running, waitingInput, waitingApproval, completed, failed, cancelled, idle, unknown

    var isWaiting: Bool { self == .waitingInput || self == .waitingApproval }
    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

enum AgentSourceClassification: String, Sendable {
    case userSession, subagent, internalSuggestion, unknown
}

/// An adapter must establish authoritative provenance and a monotonically
/// increasing sequence PER SESSION across runs. Arrival time is not ordering.
/// This is an internal read-only contract, not a claim about a desktop API.
struct AgentSessionEvent: Sendable {
    let id: AgentSessionID
    let runID: String?
    let requestID: String?
    let eventID: String
    let sequence: Int64
    let parentID: AgentSessionID?
    let classification: AgentSourceClassification
    let status: AgentActivityStatus
    let title: String
    let summary: String?
    let updatedAt: Date
}

struct AgentSessionSnapshot: Identifiable, Equatable, Sendable {
    let id: AgentSessionID
    let runID: String?
    let requestID: String?
    let sequence: Int64
    let parentID: AgentSessionID?
    let classification: AgentSourceClassification
    let status: AgentActivityStatus
    let title: String
    let summary: String?
    let updatedAt: Date
}

struct AgentSessionGroup: Identifiable, Equatable, Sendable {
    let root: AgentSessionSnapshot
    let children: [AgentSessionSnapshot]
    var id: AgentSessionID { root.id }

    /// Count a root once even if several children need input. A terminal root
    /// cannot be made active again by a late child event.
    var status: AgentActivityStatus {
        guard !root.status.isTerminal else { return root.status }
        let statuses = [root.status] + children.map(\.status)
        for candidate in [AgentActivityStatus.waitingApproval, .waitingInput, .running] {
            if statuses.contains(candidate) { return candidate }
        }
        return root.status
    }
}

enum AgentMessageMode: String, Sendable { case steer, queue, send }

struct AgentMessageRequest: Equatable, Sendable {
    let id: UUID
    let sessionID: AgentSessionID
    let turnID: String?
    let mode: AgentMessageMode
    let text: String
}

struct AgentMessageDraft: Equatable {
    var text = ""
    var delivery = AgentMessageDelivery.ready
    var request: AgentMessageRequest?
    var revision: UInt64 = 0
}

struct AgentPendingInput: Equatable, Sendable {
    let id: String
    let text: String
    let asynchronous: Bool
    var questions: [AgentInputQuestion] = []
    var canRespond = false
}

struct AgentInputOption: Equatable, Sendable {
    let label: String
    let description: String
}

struct AgentInputQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let header: String
    let text: String
    let isSecret: Bool
    let options: [AgentInputOption]
    var allowsOther = true
}

/// Response identity stays bound to the original request and turn. Answers and
/// native request handles are transient and are never part of saved drafts.
struct AgentInputResponse: Equatable, Sendable {
    let requestID: String
    let sessionID: AgentSessionID
    let turnID: String
    let answers: [String: [String]]

    func matches(_ input: AgentPendingInput) -> Bool {
        guard input.canRespond, input.id == requestID, !input.questions.isEmpty, input.questions.count <= 8,
              Set(answers.keys) == Set(input.questions.map(\.id)) else { return false }
        return answers.values.allSatisfy { values in
            values.count == 1 && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_000 }
        } && input.questions.allSatisfy { question in
            question.allowsOther || question.options.contains(where: { $0.label == answers[question.id]?.first })
        } && answers.values.flatMap { $0 }.reduce(0, { $0 + $1.utf8.count }) <= 32_000
    }
}

enum CodexTranscriptSignal: Equatable, Sendable {
    case progress(String, at: Date? = nil), question(AgentPendingInput), answered, ended, cancelled
}

struct AgentSessionContext: Equatable, Sendable {
    var cwd: String?
    var branch: String?
    var model: String?
    var prompt: String?
    var promptTurnID: String?
    var startedAt: Date?
    var toolDetail: String?
    var plan: [AgentPlanStep] = []
    var lastCompletedTool: AgentCompletedTool?
    var progressText: String?
    var pendingInput: AgentPendingInput?
    var latestActivity: AgentCurrentActivity?
    var activityAt: Date?
    var lastKnownStatus: AgentActivityStatus?

    mutating func recordActivity(_ activity: AgentCurrentActivity, at date: Date?) {
        // A delayed transcript callback must not replace a newer hook action.
        // Untimed compatibility records can establish activity only initially.
        if let previous = activityAt {
            guard let date, date >= previous else { return }
        }
        latestActivity = activity
        activityAt = date
    }
}

struct AgentCompletedTool: Equatable, Sendable {
    let name: String
    let detail: String?
    let finishedAt: Date
    var outcome: AgentToolOutcome = .completed
}

enum AgentCurrentActivity: Equatable, Sendable {
    case tool(name: String, detail: String?)
    case completedTool(name: String, detail: String?, outcome: AgentToolOutcome = .completed)
    case progress(String)
    case waiting
}

enum AgentToolKind: Equatable {
    case edit, read, command, search, plan, other

    init(name: String) {
        let component = name.components(separatedBy: "__").last ?? name
        let tool = component.split(separator: ".").last.map(String.init)?.lowercased() ?? component.lowercased()
        switch tool {
        case "edit", "write", "apply_patch", "write_file", "edit_file", "str_replace_editor": self = .edit
        case "read", "read_file", "read_text_file", "read_multiple_files": self = .read
        case "bash", "shell", "exec_command", "shell_command": self = .command
        case "glob", "grep", "search", "search_files", "web_search", "search_query": self = .search
        case "update_plan": self = .plan
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .command: return "terminal"
        case .search: return "magnifyingglass"
        case .plan: return "list.bullet"
        case .other: return "gearshape"
        }
    }

    func object(name: String, detail: String?) -> String {
        guard let detail = AgentMessagePreview.line(detail) else { return name }
        // Only file tools have file semantics. Never guess what an arbitrary
        // shell command does from words such as cat, rg or python.
        if self == .read || self == .edit { return (detail as NSString).lastPathComponent }
        return detail
    }

    func template(outcome: AgentToolOutcome?) -> String {
        switch (self, outcome) {
        case (.edit, nil): return "Editing %@"
        case (.edit, .completed): return "Edited %@"
        case (.edit, .failed): return "Failed to edit %@"
        case (.edit, .cancelled): return "Cancelled editing %@"
        case (.read, nil): return "Reading %@"
        case (.read, .completed): return "Read %@"
        case (.read, .failed): return "Failed to read %@"
        case (.read, .cancelled): return "Cancelled reading %@"
        case (.command, nil): return "Running %@"
        case (.command, .completed): return "Ran %@"
        case (.command, .failed): return "Command failed: %@"
        case (.command, .cancelled): return "Command cancelled: %@"
        case (.search, nil): return "Searching %@"
        case (.search, .completed): return "Searched %@"
        case (.search, .failed): return "Failed to search %@"
        case (.search, .cancelled): return "Cancelled searching %@"
        case (.plan, nil): return "Updating plan: %@"
        case (.plan, .completed): return "Updated plan: %@"
        case (.plan, .failed): return "Failed to update plan: %@"
        case (.plan, .cancelled): return "Cancelled updating plan: %@"
        case (.other, nil): return "Calling %@"
        case (.other, .completed): return "Finished %@"
        case (.other, .failed): return "Failed: %@"
        case (.other, .cancelled): return "Cancelled: %@"
        }
    }
}

enum AgentPanelPresentation {
    static func activity(group: AgentSessionGroup, context: AgentSessionContext?, tool: String?) -> AgentCurrentActivity? {
        guard group.status == .running else { return nil }
        if let name = AgentMessagePreview.line(tool) {
            return .tool(name: name, detail: AgentMessagePreview.line(context?.toolDetail))
        }
        if let activity = context?.latestActivity { return activity }
        if let completed = context?.lastCompletedTool {
            return .completedTool(name: completed.name, detail: completed.detail, outcome: completed.outcome)
        }
        if let text = AgentMessagePreview.line(context?.progressText) { return .progress(text) }
        return .waiting
    }

    static func userMessage(context: AgentSessionContext?, turnID: String?) -> String? {
        guard let turnID, context?.promptTurnID == turnID else { return nil }
        return AgentMessagePreview.userMessage(context?.prompt)
    }
}

/// A bounded, plain-text preview, never a transcript reader or summary generator.
enum AgentMessagePreview {
    static func line(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(240))
    }

    static func userMessage(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Recognize only explicit host attachment wrappers. Unclosed wrappers
        // are not reliable user text and must not produce a misleading row.
        if text.hasPrefix("# Files mentioned by the user:") {
            guard let request = text.range(of: "## My request:") else { return nil }
            text = String(text[request.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("<send_user_message_question_reply>") { return nil }
        let wrappers = ["image", "in-app-browser-context", "environment_context"]
        for _ in 0..<8 {
            guard let tag = wrappers.first(where: { text.hasPrefix("<" + $0 + ">") || text.hasPrefix("<" + $0 + " ") }) else { return line(text) }
            guard let close = text.range(of: "</" + tag + ">") else { return nil }
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

enum AgentPanelRoute: Hashable {
    case sessions
    case detail(AgentSessionID)
    case approval(String)
}

/// One bounded presentation state shared across hover lifetimes.
/// Attention and list order are independent from transient progress updates.
struct AgentPanelState: Equatable {
    var route = AgentPanelRoute.sessions
    var prefersSessionList = false
    var order: [AgentSessionID] = []
    var isEditing = false
    var isListInteracting = false
    private var seenApprovals: [String] = []
    private var pendingAttention: [String] = []
    private var shownInputs: [String] = []

    mutating func reconcile(groups: [AgentSessionGroup], interaction: AgentInteractionSnapshot) -> String? {
        let ids = Set(groups.map { $0.id })
        let base = order.filter { ids.contains($0) } + groups.map { $0.id }.filter { !order.contains($0) }
        if !isListInteracting {
            let positions = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($1, $0) })
            order = groups.sorted {
                func tier(_ group: AgentSessionGroup) -> Int { group.status.isWaiting ? 0 : group.status == .running ? 1 : 2 }
                let a = tier($0), b = tier($1)
                return a == b ? positions[$0.id, default: 0] < positions[$1.id, default: 0] : a < b
            }.map { $0.id }
        } else { order = base }
        if case .detail(let id) = route, !ids.contains(id) { route = .sessions }
        let currentApproval: Bool
        if case .approval(let id) = route {
            currentApproval = interaction.approvals.contains { $0.id == id }
            pendingAttention.removeAll { $0 == id }
            if !currentApproval { route = .sessions }
        } else { currentApproval = false }
        let fresh = interaction.approvals.filter { !seenApprovals.contains($0.id) }
        seenApprovals = Array((seenApprovals + fresh.map { $0.id }).suffix(200))
        pendingAttention.removeAll { id in !interaction.approvals.contains { $0.id == id } }
        pendingAttention.append(contentsOf: fresh.map { $0.id })
        guard !isEditing, !isListInteracting, !currentApproval else { return nil }
        if let request = pendingAttention.first {
            pendingAttention.removeFirst(); route = .approval(request); return request
        }
        let inputs = groups.compactMap { group -> (AgentSessionID, String)? in
            guard let input = interaction.contexts[group.id]?.pendingInput else { return nil }
            return (group.id, "input-" + group.id.sessionID + "-" + input.id)
        }
        if case .detail(let id) = route, let input = inputs.first(where: { $0.0 == id }), shownInputs.contains(input.1) { return nil }
        if let input = inputs.first(where: { !shownInputs.contains($0.1) }) {
            shownInputs = Array((shownInputs + [input.1]).suffix(100))
            route = .detail(input.0); return input.1
        }
        return nil
    }
}
