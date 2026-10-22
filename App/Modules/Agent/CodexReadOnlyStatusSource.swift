import Foundation

/// Opt-in adapter for bounded, user-tagged local Codex catalog metadata. It cannot answer
/// approval requests, send input, or determine completion from elapsed time.
@MainActor
final class CodexReadOnlyStatusSource: AgentStatusSource {
    private var reader: CodexReadOnlyReader?
    private let root: URL
    private var receive: (@MainActor (AgentSourceUpdate) -> Void)?
    private var refreshToken: ModuleRefreshToken?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)) {
        self.root = root
    }

    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        stop()
        self.receive = receive
        reader = CodexReadOnlyReader(root: root)
        receive(.connection(.disconnected))
        refreshToken = ModuleRefreshScheduler.shared.register(
            id: "agent.codex.readonly", name: "Agent", module: .builtIn(.agent),
            policy: .interval(5, tolerance: 1), enabled: { [weak self] in self?.receive != nil }
        ) { [weak self] in self?.refresh() }
        refresh()
    }

    func stop() {
        generation = UUID()
        ModuleRefreshScheduler.shared.unregister(refreshToken)
        refreshToken = nil
        task?.cancel()
        task = nil
        receive = nil
        // A new actor on the next start discards all source-local state.
        reader = nil
    }

    deinit {
        task?.cancel()
        let token = refreshToken
        Task { @MainActor in ModuleRefreshScheduler.shared.unregister(token) }
    }

    func refresh() {
        guard task == nil, let reader, receive != nil else { return }
        let expectedGeneration = generation
        task = Task { [weak self] in
            let snapshot = await reader.snapshot()
            guard !Task.isCancelled, let self, expectedGeneration == self.generation else { return }
            self.task = nil
            self.receive?(.connection(snapshot.connection))
            guard snapshot.connection == .connected else { return }
            for event in snapshot.events {
                self.receive?(.event(event))
                self.receive?(.navigation(event.id, AgentVerifiedNavigationTarget(desktopThreadID: event.id.sessionID)))
            }
            self.receive?(.retainingSessions(Set(snapshot.events.map(\.id))))
        }
    }
}
