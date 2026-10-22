import Foundation
import SwiftUI

enum EnergyMode: String, CaseIterable, Identifiable {
    case normal
    case smart
    case lowPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .smart: return "Smart"
        case .lowPower: return "Low Power"
        }
    }

    var description: String {
        switch self {
        case .normal:
            return "Keep refresh behavior responsive."
        case .smart:
            return "Reduce background work while collapsed and restore quickly on hover."
        case .lowPower:
            return "Slow non-essential refresh and reduce background work."
        }
    }
}

enum ModuleRefreshPolicy: Equatable {
    case eventDriven
    case interval(TimeInterval, tolerance: TimeInterval)
    case activeOnly(TimeInterval, tolerance: TimeInterval)
    case visibleOnly(TimeInterval, tolerance: TimeInterval)
    /// Local UI timekeeping, never network polling; keeps its cadence in Low Power Mode.
    case presentationOnly(TimeInterval, tolerance: TimeInterval)
    case manual

}

struct ModuleRefreshToken: Hashable {
    fileprivate let id: String
    fileprivate let registrationID: UUID
}

struct IslandActivityState: Equatable {
    var islandState: IslandState
    var activeModule: ActiveModule?
    var fullExpandedTab: FullExpandedTab
    var isHovering: Bool
    var isAppActive: Bool
    var compactModule: ActiveModule? = nil
    var homeModules: Set<ActiveModule> = []

    func isVisible(_ module: ActiveModule) -> Bool {
        switch islandState {
        case .compact: return compactModule == module
        case .expanded: return activeModule == module
        case .fullExpanded:
            if case .module(let selected) = fullExpandedTab { return selected == module }
            return homeModules.contains(module)
        }
    }
}

struct EnergyDiagnosticsSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let moduleName: String
    let policy: ModuleRefreshPolicy
    let status: String
    let nextFireDate: Date?
    let lastRunDate: Date?
    let lastDispatchDuration: TimeInterval?
}

@MainActor
final class ModuleRefreshScheduler: ObservableObject {
    static let shared = ModuleRefreshScheduler()

    @Published private(set) var diagnostics: [EnergyDiagnosticsSnapshot] = []

    private struct Job {
        let registrationID = UUID()
        var scheduleID = UUID()
        let id: String
        let name: String
        let module: ActiveModule?
        let policy: ModuleRefreshPolicy
        let enabled: @MainActor () -> Bool
        let action: @MainActor () -> Void
        var nextFireDate: Date?
        var lastRunDate: Date?
        var lastDispatchDuration: TimeInterval?
        var status: String = "Scheduled"
    }

    private var jobs: [String: Job] = [:]
    // Timer ownership is kept here, keyed by job id, deliberately separate from
    // the Job struct. Jobs are value types stored in a dictionary, so reading a
    // job into a local `var`, mutating it, and writing it back can clobber a
    // timer that a re-entrant call (action -> updateActivityState -> reschedule)
    // installed in the meantime, orphaning a live RunLoop timer that can never be
    // invalidated. Routing all timer mutations through this dictionary keeps
    // ownership authoritative and re-entrancy-safe.
    private var timers: [String: Timer] = [:]
    private var recentActivity: [(date: Date, duration: TimeInterval)] = []
    private let energyModeProvider: @MainActor () -> EnergyMode
    private var lastEffectiveEnergyMode: EnergyMode
    private var activityState = IslandActivityState(
        islandState: .compact,
        activeModule: nil,
        fullExpandedTab: .home,
        isHovering: false,
        isAppActive: true
    )

    private init(energyModeProvider: @escaping @MainActor () -> EnergyMode = { AppState.shared.effectiveEnergyMode }) {
        self.energyModeProvider = energyModeProvider
        lastEffectiveEnergyMode = energyModeProvider()
    }

#if DEBUG
    /// Test seam: build an isolated instance instead of the shared singleton.
    convenience init(
        isolatedForTesting: Bool,
        energyModeProvider: @escaping @MainActor () -> EnergyMode = { .normal }
    ) {
        self.init(energyModeProvider: energyModeProvider)
        _ = isolatedForTesting
    }

    var scheduledTimerCountForTesting: Int { timers.count }
    var jobCountForTesting: Int { jobs.count }
#endif

    @discardableResult
    func register(
        id: String,
        name: String,
        module: ActiveModule? = nil,
        policy: ModuleRefreshPolicy,
        enabled: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) -> ModuleRefreshToken {
        unregister(id: id)

        let job = Job(
            id: id,
            name: name,
            module: module,
            policy: policy,
            enabled: enabled,
            action: action
        )
        jobs[id] = job
        reschedule(id: id, runIfNewlyVisible: false)
        updateDiagnostics()
        return ModuleRefreshToken(id: id, registrationID: job.registrationID)
    }

    func unregister(_ token: ModuleRefreshToken?) {
        guard let token, jobs[token.id]?.registrationID == token.registrationID else { return }
        unregister(id: token.id)
    }

    func unregister(id: String) {
        invalidateTimer(id: id)
        jobs.removeValue(forKey: id)
        updateDiagnostics()
    }

    private func invalidateTimer(id: String) {
        timers[id]?.invalidate()
        timers.removeValue(forKey: id)
    }

    func updateActivityState(_ nextState: IslandActivityState) {
        let nextEnergyMode = energyModeProvider()
        // System Low Power Mode can change without any island activity change.
        guard activityState != nextState || lastEffectiveEnergyMode != nextEnergyMode else { return }
        let previousState = activityState
        activityState = nextState
        lastEffectiveEnergyMode = nextEnergyMode

        for id in jobs.keys {
            let becameVisible = jobIsVisible(jobs[id]) && !jobIsVisible(jobs[id], state: previousState)
            reschedule(id: id, runIfNewlyVisible: becameVisible)
        }
        updateDiagnostics()
    }

    func refreshScheduling() {
        lastEffectiveEnergyMode = energyModeProvider()
        for id in jobs.keys {
            reschedule(id: id, runIfNewlyVisible: false)
        }
        updateDiagnostics()
    }

    /// Invalidate all owned timers before the app exits.
    func shutdown() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        jobs.removeAll()
        updateDiagnostics()
    }

    func runNow(id: String) {
        guard jobs[id] != nil else { return }
        run(id: id)
    }

    private func reschedule(id: String, runIfNewlyVisible: Bool) {
        guard var job = jobs[id] else { return }

        invalidateTimer(id: id)
        job.nextFireDate = nil
        job.scheduleID = UUID()

        let enabled = job.enabled()
        guard jobs[id]?.registrationID == job.registrationID else { return }
        guard enabled else {
            job.status = "Disabled"
            jobs[id] = job
            return
        }

        guard let schedule = effectiveSchedule(for: job) else {
            job.status = passiveStatus(for: job)
            jobs[id] = job
            return
        }

        let interval = schedule.interval
        let nextFireDate = Date().addingTimeInterval(interval)
        let registrationID = job.registrationID
        let scheduleID = job.scheduleID
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.jobs[id]?.registrationID == registrationID,
                      self.jobs[id]?.scheduleID == scheduleID else { return }
                self.run(id: id)
            }
        }
        timer.tolerance = schedule.tolerance
        RunLoop.main.add(timer, forMode: .common)

        timers[id] = timer
        job.nextFireDate = nextFireDate
        job.status = "Scheduled"
        jobs[id] = job

        if runIfNewlyVisible, shouldRunWhenBecomingVisible(job) {
            run(id: id)
        }
    }

    private func run(id: String) {
        guard let job = jobs[id], job.enabled() else {
            reschedule(id: id, runIfNewlyVisible: false)
            return
        }

        guard jobs[id]?.registrationID == job.registrationID else { return }
        guard let schedule = effectiveSchedule(for: job) else {
            reschedule(id: id, runIfNewlyVisible: false)
            return
        }

        let start = Date()
        job.action()
        let duration = Date().timeIntervalSince(start)
        recordActivity(duration: duration)

        // The action may unregister this job or replace it under the same ID.
        // Never restore the pre-action value or stamp the replacement's history.
        guard var current = jobs[id], current.registrationID == job.registrationID else {
            updateDiagnostics()
            return
        }
        current.lastRunDate = start
        current.lastDispatchDuration = duration
        // Reentrant rescheduling owns its newer deadline and paused/disabled state.
        if current.scheduleID == job.scheduleID {
            current.nextFireDate = Date().addingTimeInterval(schedule.interval)
        }
        jobs[id] = current

        updateDiagnostics()
    }

    private func effectiveSchedule(for job: Job) -> (interval: TimeInterval, tolerance: TimeInterval)? {
        switch job.policy {
        case .eventDriven, .manual:
            return nil
        case .interval(let interval, let tolerance):
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        case .activeOnly(let interval, let tolerance):
            guard jobIsVisible(job) || activityState.isHovering else { return nil }
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        case .visibleOnly(let interval, let tolerance):
            guard jobIsVisible(job) else { return nil }
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        case .presentationOnly(let interval, let tolerance):
            guard jobIsVisible(job) else { return nil }
            return (max(interval, 1), tolerance)
        }
    }

    private func adjustedSchedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        module: ActiveModule?
    ) -> (interval: TimeInterval, tolerance: TimeInterval) {
        let mode = energyModeProvider()
        var adjustedInterval = max(interval, minimumInterval(for: module))
        var adjustedTolerance = max(tolerance, adjustedInterval * 0.15)

        if mode == .smart,
           activityState.islandState == .compact,
           !activityState.isHovering,
           module.map({ !activityState.isVisible($0) }) ?? true {
            adjustedInterval = max(adjustedInterval * 4, 30)
            adjustedTolerance = max(adjustedTolerance, adjustedInterval * 0.35)
        } else if mode == .lowPower {
            adjustedInterval = max(adjustedInterval * 3, 60)
            adjustedTolerance = max(adjustedTolerance, adjustedInterval * 0.4)
        }

        return (adjustedInterval, adjustedTolerance)
    }

    private func minimumInterval(for module: ActiveModule?) -> TimeInterval {
        return 1
    }

    private func passiveStatus(for job: Job) -> String {
        switch job.policy {
        case .eventDriven:
            return "Event driven"
        case .manual:
            return "Manual"
        case .activeOnly, .visibleOnly, .presentationOnly:
            return job.enabled() ? "Paused" : "Disabled"
        case .interval:
            return "Paused"
        }
    }

    private func jobIsVisible(_ job: Job?) -> Bool {
        jobIsVisible(job, state: activityState)
    }

    private func jobIsVisible(_ job: Job?, state: IslandActivityState) -> Bool {
        guard let module = job?.module else {
            return state.isAppActive || state.isHovering
        }
        return state.isVisible(module)
    }

    private func shouldRunWhenBecomingVisible(_ job: Job) -> Bool {
        guard job.enabled() else { return false }
        guard let lastRunDate = job.lastRunDate else { return true }
        guard let schedule = effectiveSchedule(for: job) else { return false }
        return Date().timeIntervalSince(lastRunDate) >= min(schedule.interval, 5)
    }

    private func recordActivity(duration: TimeInterval) {
        let now = Date()
        recentActivity.append((now, duration))
        recentActivity.removeAll { now.timeIntervalSince($0.date) > 120 }

        let totalDuration = recentActivity.reduce(0) { $0 + $1.duration }
        if recentActivity.count >= 80 || totalDuration >= 8 {
            EnergySuggestionPresenter.shared.suggestLowPower(reason: .sustainedActivity)
            recentActivity.removeAll()
        }
    }

    private func updateDiagnostics() {
        diagnostics = jobs.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { job in
                EnergyDiagnosticsSnapshot(
                    id: job.id,
                    name: job.name,
                    moduleName: job.module?.displayName ?? "App",
                    policy: job.policy,
                    status: job.status,
                    nextFireDate: job.nextFireDate,
                    lastRunDate: job.lastRunDate,
                    lastDispatchDuration: job.lastDispatchDuration
                )
            }
    }
}
