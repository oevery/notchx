import XCTest
@testable import NotchX

@MainActor
final class ModuleRefreshSchedulerTests: XCTestCase {
    func testVisibilityComesOnlyFromTheSuppliedSnapshotAndStaysIsolated() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        let other = ModuleRefreshScheduler(isolatedForTesting: true)
        defer { scheduler.shutdown(); other.shutdown() }
        for value in [scheduler, other] {
            value.register(id: "tools", name: "Tools", module: .builtIn(.tools), policy: .visibleOnly(60, tolerance: 1), action: {})
        }
        var state = IslandActivityState(islandState: .fullExpanded, activeModule: nil,
                                        fullExpandedTab: .home, isHovering: false, isAppActive: false,
                                        homeModules: [.builtIn(.tools)])
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
        XCTAssertEqual(other.scheduledTimerCountForTesting, 0)
        state.homeModules = []
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        state.islandState = .compact
        state.compactModule = .builtIn(.tools)
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
    }

    func testVisiblePresentationClockIsResponsiveInLowPowerButStopsWhenHidden() throws {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyModeProvider: { .lowPower })
        defer { scheduler.shutdown() }
        var ticks = 0
        scheduler.register(id: "clock", name: "Clock", policy: .presentationOnly(1, tolerance: 0.2)) { ticks += 1 }
        scheduler.register(id: "poll", name: "Poll", policy: .interval(1, tolerance: 0.2), action: {})
        let clock = try XCTUnwrap(scheduler.diagnostics.first { $0.id == "clock" }?.nextFireDate)
        let poll = try XCTUnwrap(scheduler.diagnostics.first { $0.id == "poll" }?.nextFireDate)
        XCTAssertLessThan(clock.timeIntervalSinceNow, 2)
        XCTAssertGreaterThan(poll.timeIntervalSince(clock), 50)
        scheduler.updateActivityState(IslandActivityState(islandState: .compact, activeModule: nil,
                                                          fullExpandedTab: .home, isHovering: false, isAppActive: false))
        XCTAssertNil(scheduler.diagnostics.first { $0.id == "clock" }?.nextFireDate)
        scheduler.runNow(id: "clock")
        XCTAssertEqual(ticks, 0)
    }

    func testEnergyModeChangesRescheduleWithoutActivityChanges() throws {
        var mode = EnergyMode.normal
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyModeProvider: { mode })
        defer { scheduler.shutdown() }
        let state = IslandActivityState(islandState: .compact, activeModule: nil,
                                        fullExpandedTab: .home, isHovering: false, isAppActive: true)
        scheduler.register(id: "energy", name: "Energy", policy: .interval(5, tolerance: 1), action: {})
        let normalDeadline = try XCTUnwrap(scheduler.diagnostics.first?.nextFireDate)
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.diagnostics.first?.nextFireDate, normalDeadline,
                       "Unchanged activity and energy mode must preserve the deadline")

        mode = .lowPower
        scheduler.updateActivityState(state)
        let lowPowerDeadline = try XCTUnwrap(scheduler.diagnostics.first?.nextFireDate)
        XCTAssertGreaterThan(lowPowerDeadline.timeIntervalSince(normalDeadline), 50)
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.diagnostics.first?.nextFireDate, lowPowerDeadline)

        mode = .normal
        scheduler.updateActivityState(state)
        let restoredDeadline = try XCTUnwrap(scheduler.diagnostics.first?.nextFireDate)
        XCTAssertLessThan(restoredDeadline.timeIntervalSince(lowPowerDeadline), -50)
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.diagnostics.first?.nextFireDate, restoredDeadline)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
    }

    func testExplicitRefreshRecordsEnergyModeWithoutLaterReset() throws {
        var mode = EnergyMode.normal
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyModeProvider: { mode })
        defer { scheduler.shutdown() }
        let state = IslandActivityState(islandState: .compact, activeModule: nil,
                                        fullExpandedTab: .home, isHovering: false, isAppActive: true)
        scheduler.register(id: "energy", name: "Energy", policy: .interval(5, tolerance: 1), action: {})
        mode = .lowPower
        scheduler.refreshScheduling()
        let deadline = try XCTUnwrap(scheduler.diagnostics.first?.nextFireDate)
        scheduler.updateActivityState(state)
        XCTAssertEqual(scheduler.diagnostics.first?.nextFireDate, deadline,
                       "An explicit refresh already applied the new energy mode")
    }

    func testOldTokenCannotUnregisterReplacement() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        let oldToken = scheduler.register(id: "reused", name: "Old", policy: .interval(60, tolerance: 1), action: {})
        var runs = 0
        let currentToken = scheduler.register(id: "reused", name: "New", policy: .interval(60, tolerance: 1)) { runs += 1 }
        scheduler.unregister(oldToken)
        scheduler.runNow(id: "reused")
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(scheduler.jobCountForTesting, 1)
        scheduler.unregister(currentToken)
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }

    // Regression test for the main-thread freeze caused by leaked RunLoop timers.
    //
    // A module's refresh `action` can re-enter the scheduler (for example when a
    // refresh nudges AppState, which pushes a new activity state and triggers a
    // reschedule). The original implementation stored each Timer inside the Job
    // value type; `run(id:)` read a Job copy, invoked the action, then wrote the
    // stale copy back — clobbering any timer the re-entrant call had installed.
    // The clobbered timer stayed armed on RunLoop.main but lost its only owning
    // reference, so it could never be invalidated. Over days these orphans piled
    // up until __CFArmNextTimerInMode turned into an O(n) scan that pegged the
    // main thread and froze the UI.
    //
    // One job must own exactly one live timer no matter how often its action
    // re-enters the scheduler.
    func testReentrantActionDoesNotOrphanTimers() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var runCount = 0

        scheduler.register(
            id: "test.job",
            name: "Test Job",
            policy: .interval(0.05, tolerance: 0.01),
            enabled: { true }
        ) { [weak scheduler] in
            runCount += 1
            // Re-enter mid-run, the way a real module refresh can.
            scheduler?.refreshScheduling()
        }

        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        for _ in 0..<200 {
            scheduler.runNow(id: "test.job")
        }

        XCTAssertGreaterThan(runCount, 0, "action should have executed")
        XCTAssertEqual(
            scheduler.scheduledTimerCountForTesting,
            scheduler.jobCountForTesting,
            "live timers must track the number of jobs, never accumulate"
        )
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }

    // Repeated re-registration of the same id must not accumulate timers either.
    func testReRegisterKeepsSingleTimer() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)

        for _ in 0..<50 {
            scheduler.register(
                id: "test.job",
                name: "Test Job",
                policy: .interval(1, tolerance: 0.1),
                enabled: { true },
                action: {}
            )
        }

        XCTAssertEqual(scheduler.jobCountForTesting, 1)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }
    func testDisablingModuleCancelsItsTimerAndPreventsRefresh() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var enabled = true
        var calls = 0
        scheduler.register(id: "disable", name: "Disable", policy: .interval(60, tolerance: 1),
                           enabled: { enabled }, action: { calls += 1 })
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
        enabled = false
        scheduler.refreshScheduling()
        scheduler.runNow(id: "disable")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(scheduler.diagnostics.first?.status, "Disabled")
        scheduler.unregister(id: "disable")
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
    }

    func testEventDrivenAndManualPoliciesDoNotAllocateTimers() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        for (id, policy) in [("event", ModuleRefreshPolicy.eventDriven), ("manual", .manual)] {
            scheduler.register(id: id, name: id, policy: policy, action: {})
        }
        XCTAssertEqual(scheduler.jobCountForTesting, 2)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        scheduler.unregister(id: "event")
        scheduler.unregister(id: "manual")
    }
    func testActionCanUnregisterItselfWithoutResurrection() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var calls = 0
        scheduler.register(id: "self-remove", name: "Self remove", policy: .interval(60, tolerance: 1)) {
            calls += 1
            scheduler.unregister(id: "self-remove")
        }
        scheduler.runNow(id: "self-remove")
        scheduler.runNow(id: "self-remove")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        XCTAssertTrue(scheduler.diagnostics.isEmpty)
    }

    func testActionCanReplaceItsRegistrationWithoutStaleWriteback() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        defer { scheduler.shutdown() }
        var originalCalls = 0
        var replacementCalls = 0
        scheduler.register(id: "replace", name: "Original", policy: .interval(60, tolerance: 1)) {
            originalCalls += 1
            scheduler.register(id: "replace", name: "Replacement", policy: .interval(120, tolerance: 2)) {
                replacementCalls += 1
            }
        }
        scheduler.runNow(id: "replace")
        XCTAssertEqual(scheduler.diagnostics.first?.name, "Replacement")
        XCTAssertNil(scheduler.diagnostics.first?.lastRunDate)
        scheduler.runNow(id: "replace")
        XCTAssertEqual(originalCalls, 1)
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(scheduler.jobCountForTesting, 1)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
    }

    func testShutdownDuringActionDoesNotRestoreJobsOrTimers() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var calls = 0
        scheduler.register(id: "shutdown", name: "Shutdown", policy: .interval(60, tolerance: 1)) {
            calls += 1
            scheduler.shutdown()
        }
        scheduler.register(id: "other", name: "Other", policy: .interval(60, tolerance: 1)) { calls += 10 }
        scheduler.runNow(id: "shutdown")
        scheduler.runNow(id: "other")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        XCTAssertTrue(scheduler.diagnostics.isEmpty)
    }

    func testReentrantDisablePreservesDisabledDiagnostics() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        defer { scheduler.shutdown() }
        var enabled = true
        scheduler.register(id: "disable-in-action", name: "Disable in action", policy: .interval(60, tolerance: 1),
                           enabled: { enabled }) {
            enabled = false
            scheduler.refreshScheduling()
        }
        scheduler.runNow(id: "disable-in-action")
        XCTAssertEqual(scheduler.diagnostics.first?.status, "Disabled")
        XCTAssertNil(scheduler.diagnostics.first?.nextFireDate)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }

}
