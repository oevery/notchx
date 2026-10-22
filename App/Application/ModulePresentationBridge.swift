import Combine
import Foundation

/// The host owns its cross-module consumers. Module runtimes never notify a
/// global AppState, and disabled modules retain no host subscriptions.
@MainActor
final class ModulePresentationBridge {
    private weak var state: AppState?
    private let music: @MainActor () -> NowPlayingManager
    private let agent: @MainActor () -> AgentManager
    private let permissions: PermissionState
    private let calendarAccessDidChange: @MainActor () -> Void
    private var subscriptions: [ModuleType: Set<AnyCancellable>] = [:]
    var subscribedModules: Set<ModuleType> { Set(subscriptions.keys) }

    init(state: AppState, music: @escaping @MainActor () -> NowPlayingManager = { .shared },
         agent: @escaping @MainActor () -> AgentManager = { .shared },
         permissions: PermissionState? = nil,
         calendarAccessDidChange: @escaping @MainActor () -> Void = { CalendarManager.shared.refreshAccessStatus() }) {
        self.state = state
        self.music = music
        self.agent = agent
        self.permissions = permissions ?? .shared
        self.calendarAccessDidChange = calendarAccessDidChange
    }

    func reconcile() {
        guard let state else { stop(); return }
        for module in Array(subscriptions.keys) where !state.isModuleEnabled(module) {
            subscriptions.removeValue(forKey: module)
        }
        for module in [ModuleType.nowPlaying, .agent, .calendar] where state.isModuleEnabled(module) && subscriptions[module] == nil {
            var observers = Set<AnyCancellable>()
            switch module {
            case .nowPlaying:
                music().objectWillChange
                    .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
                    .sink { [weak state] _ in
                        guard let state, state.nowPlayingEnabled else { return }
                        state.modulePresentationDidChange()
                    }.store(in: &observers)
            case .agent:
                let manager = agent()
                manager.objectWillChange
                    .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
                    .sink { [weak state] _ in
                        guard let state, state.agentEnabled else { return }
                        state.modulePresentationDidChange()
                    }.store(in: &observers)
                manager.$attentionRequestID.removeDuplicates()
                    .receive(on: RunLoop.main)
                    .sink { [weak state] request in
                        guard let state, state.agentEnabled, request != nil else { return }
                        state.presentAgentAttentionIfAvailable()
                    }.store(in: &observers)
                manager.$codexEnabled.removeDuplicates()
                    .receive(on: RunLoop.main)
                    .sink { [weak state] enabled in
                        if !enabled { state?.clearPendingEvents(for: .agent) }
                    }.store(in: &observers)
            case .calendar:
                permissions.$snapshot.compactMap { $0?.granted.contains(.calendar) }
                    .removeDuplicates()
                    .receive(on: RunLoop.main)
                    .sink { [weak state, calendarAccessDidChange] _ in
                        guard state?.calendarEnabled == true else { return }
                        calendarAccessDidChange()
                    }.store(in: &observers)
            default: break
            }
            subscriptions[module] = observers
        }
    }

    func stop() { subscriptions.removeAll() }
}
