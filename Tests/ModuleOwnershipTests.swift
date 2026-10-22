import AppKit
import XCTest
@testable import NotchX

@MainActor
final class ModuleOwnershipTests: XCTestCase {
    private func withState(_ body: (AppState, UserDefaults, String) async throws -> Void) async rethrows {
        let domain = "app.notchx.tests.ownership." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        for module in ModuleType.allCases { state.setModuleEnabled(module, enabled: false) }
        defer { defaults.removePersistentDomain(forName: domain) }
        try await body(state, defaults, domain)
    }

    func testSpacesPreferenceAppliesToInitialAndExistingPanelsWithoutChangingOtherPolicy() async throws {
        try await withState { state, defaults, _ in
            state.showOnAllSpaces = false
            let controller = IslandWindowController(appState: state, pointerSource: {
                IslandPointerSnapshot(location: NSPoint(x: -100_000, y: -100_000), pressedButtons: 0)
            })
            controller.showIsland()
            defer {
                controller.hideIsland()
                controller.windows.forEach { $0.contentView = nil; $0.close() }
            }
            XCTAssertFalse(controller.windows.isEmpty)
            XCTAssertTrue(controller.windows.allSatisfy { !$0.collectionBehavior.contains(.canJoinAllSpaces) })
            state.showOnAllSpaces = true
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try await NativeUI.waitFor("existing panels adopt all-Spaces policy") {
                controller.windows.allSatisfy { $0.collectionBehavior.contains(.canJoinAllSpaces) }
            }
            state.showOnAllSpaces = false
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try await NativeUI.waitFor("existing panels leave all-Spaces policy") {
                controller.windows.allSatisfy { !$0.collectionBehavior.contains(.canJoinAllSpaces) }
            }
            XCTAssertTrue(controller.windows.allSatisfy { $0.collectionBehavior.contains(.stationary) && $0.collectionBehavior.contains(.ignoresCycle) })
        }
    }

    func testLoginRegistrationFailureAndExternalChangesUseSystemReadback() {
        enum Failure: Error { case registration }
        var actual = false
        var fails = true
        let login = LaunchAtLoginState(read: { actual }, write: { value in
            if fails { throw Failure.registration }
            actual = value
        })
        login.setEnabled(true)
        XCTAssertFalse(login.isEnabled)
        XCTAssertNotNil(login.errorMessage)
        fails = false
        login.setEnabled(true)
        XCTAssertTrue(login.isEnabled)
        XCTAssertNil(login.errorMessage)
        actual = false
        login.refresh()
        XCTAssertFalse(login.isEnabled)
    }

    func testIsolatedModuleTogglesOnlyCallTheirInstalledHostAndDoNotTouchSharedScheduling() async {
        await withState { state, _, _ in
            let jobs = ModuleRefreshScheduler.shared.diagnostics
            var transitions = 0
            state.moduleEnablementDidChange = { transitions += 1 }
            state.setModuleEnabled(.weather, enabled: true)
            state.setModuleEnabled(.weather, enabled: true)
            state.setModuleEnabled(.weather, enabled: false)
            XCTAssertEqual(transitions, 2)
            XCTAssertEqual(ModuleRefreshScheduler.shared.diagnostics, jobs)
        }
    }

    func testUnusedNativeBacklightCapabilityDoesNotRegisterAProducer() {
        let before = ModuleRefreshScheduler.shared.diagnostics
        let manager = KeyboardBacklightManager.shared
        manager.setBrightness(0.8)
        manager.setEnabled(false)
        XCTAssertEqual(ModuleRefreshScheduler.shared.diagnostics, before)
    }

    func testIdleModulePolicyUpdatesSchedulingWithoutAnUnrelatedEvent() async {
        await withState { state, _, _ in
            state.weatherEnabled = true
            state.batteryEnabled = true
            let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
            state.refreshScheduler = scheduler
            defer { scheduler.shutdown(); state.refreshScheduler = nil }
            scheduler.register(id: "weather", name: "Weather", module: .builtIn(.weather),
                               policy: .visibleOnly(60, tolerance: 1), action: {})
            state.refreshEnergyState()
            XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
            state.presentationPreferences.idleContent = .weather
            XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
            state.presentationPreferences.idleContent = .battery
            XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        }
    }

    func testRestoreUsesTheInjectedDomainAndWeatherPreferenceAuthority() async {
        await withState { state, defaults, _ in
            let liveUnit = WeatherPreferences.shared.temperatureUnit
            state.weatherPreferences.temperatureUnit = .fahrenheit
            state.weatherPreferences.windUnit = .metersPerSecond
            defaults.set("kept", forKey: "unrelated")
            let restore = SettingsRestoreSession(appState: state)
            restore.requestModuleRestore(.weather)
            restore.confirmModuleRestore()
            XCTAssertEqual(state.weatherPreferences.temperatureUnit, .celsius)
            XCTAssertEqual(state.weatherPreferences.windUnit, .automatic)
            XCTAssertEqual(defaults.string(forKey: SettingsDefaults.Weather.temperatureUnit.key), "celsius")
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "kept")
            XCTAssertEqual(WeatherPreferences.shared.temperatureUnit, liveUnit)
        }
    }

    func testHostConsumersDetachOnDisableWithoutStoppingSharedInfrastructure() async throws {
        try await withState { state, _, _ in
            var factoryCalls = 0
            let manager = AgentManager()
            let bridge = ModulePresentationBridge(state: state, music: {
                XCTFail("Disabled music must not be resolved")
                return .shared
            }, agent: { factoryCalls += 1; return manager })
            let sharedScheduler = ModuleRefreshScheduler(isolatedForTesting: true)
            var sharedRuns = 0
            sharedScheduler.register(id: "shared", name: "Shared", policy: .interval(60, tolerance: 1)) { sharedRuns += 1 }
            defer { bridge.stop(); sharedScheduler.shutdown() }
            bridge.reconcile()
            XCTAssertTrue(bridge.subscribedModules.isEmpty)
            XCTAssertEqual(factoryCalls, 0)
            for cycle in 1...3 {
                state.agentEnabled = true
                bridge.reconcile()
                bridge.reconcile()
                XCTAssertEqual(factoryCalls, cycle)
                XCTAssertEqual(bridge.subscribedModules, [.agent])
                let before = state.modulePresentationRevision
                for _ in 0..<5 { manager.objectWillChange.send() }
                try await NativeUI.waitFor("one live host consumer") { state.modulePresentationRevision > before }
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertEqual(state.modulePresentationRevision, before + 1, "Repeated reconciliation must not duplicate consumers")
                state.agentEnabled = false
                bridge.reconcile()
                let stopped = state.modulePresentationRevision
                manager.objectWillChange.send()
                try await Task.sleep(for: .milliseconds(25))
                XCTAssertTrue(bridge.subscribedModules.isEmpty)
                XCTAssertEqual(state.modulePresentationRevision, stopped)
                sharedScheduler.runNow(id: "shared")
                XCTAssertEqual(sharedRuns, cycle)
            }
        }
    }

    func testPermissionRefreshDiscardsOlderCompletionAndRequestsPublishReadback() async throws {
        var reads: [CheckedContinuation<PermissionSnapshot, Never>] = []
        let permissions = PermissionState(read: { await withCheckedContinuation { reads.append($0) } }, request: { _ in })
        let first = Task { await permissions.refresh() }
        try await NativeUI.waitFor("first permission read") { reads.count == 1 }
        let second = Task { await permissions.refresh() }
        try await NativeUI.waitFor("second permission read") { reads.count == 2 }
        let granted = PermissionSnapshot(granted: [.microphone], microphone: .authorized)
        reads[1].resume(returning: granted)
        await second.value
        reads[0].resume(returning: PermissionSnapshot())
        await first.value
        XCTAssertEqual(permissions.snapshot, granted)
        var actual = PermissionSnapshot()
        var requests = 0
        let requested = PermissionState(read: { actual }, request: { permission in
            requests += 1
            actual.granted.insert(permission)
        })
        await requested.request(.calendar)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(requested.snapshot?.granted, [.calendar])
        XCTAssertTrue(requested.requesting.isEmpty)
    }

    func testCalendarPermissionRecoveryIsEventDrivenAndStopsConsumingWhenDisabled() async throws {
        try await withState { state, _, _ in
            var actual = PermissionSnapshot()
            let permissions = PermissionState(read: { actual }, request: { _ in })
            var refreshes = 0
            let bridge = ModulePresentationBridge(state: state, permissions: permissions, calendarAccessDidChange: { refreshes += 1 })
            defer { bridge.stop() }
            state.calendarEnabled = true
            bridge.reconcile()
            await permissions.refresh()
            try await NativeUI.waitFor("initial consent snapshot reaches calendar") { refreshes == 1 }
            actual.granted.insert(.calendar)
            await permissions.refresh()
            try await NativeUI.waitFor("grant completion restores calendar without activation or hover") { refreshes == 2 }
            await permissions.refresh()
            await NativeUI.drainMainQueue()
            XCTAssertEqual(refreshes, 2, "Unchanged snapshots must not repeat module I/O")
            state.calendarEnabled = false
            bridge.reconcile()
            actual.granted.remove(.calendar)
            await permissions.refresh()
            await NativeUI.drainMainQueue()
            XCTAssertEqual(refreshes, 2)
            XCTAssertFalse(bridge.subscribedModules.contains(.calendar))
            state.calendarEnabled = true
            bridge.reconcile()
            try await NativeUI.waitFor("reenable reads retained shared snapshot") { refreshes == 3 }
            XCTAssertEqual(permissions.snapshot, actual)
            actual.granted.insert(.calendar)
            await permissions.refresh() // delivery is queued on RunLoop.main
            state.calendarEnabled = false
            bridge.reconcile()
            state.calendarEnabled = true
            bridge.reconcile()
            try await NativeUI.waitFor("only the replacement consumer receives queued consent") { refreshes == 4 }
            await NativeUI.drainMainQueue()
            XCTAssertEqual(refreshes, 4)
        }
    }

    func testNotificationPermissionConsumerTracksSharedReadbackAndReleasesOnDisable() async {
        await withState { state, _, _ in
            state.notificationsEnabled = true
            var actual = PermissionSnapshot(granted: [.notifications], notifications: .authorized)
            let permissions = PermissionState(read: { actual }, request: { _ in })
            let manager = NotificationManager(state: state, observesSystemEvents: false, permissions: permissions)
            manager.setEnabled(true)
            defer { manager.setEnabled(false) }
            await permissions.refresh()
            XCTAssertTrue(manager.hasPermission)
            actual = PermissionSnapshot(notifications: .denied)
            await permissions.refresh()
            XCTAssertFalse(manager.hasPermission)
            manager.setEnabled(false)
            actual = PermissionSnapshot(granted: [.notifications], notifications: .authorized)
            await permissions.refresh()
            XCTAssertFalse(manager.hasPermission, "Stopped module does not consume shared updates")
            manager.setEnabled(true)
            XCTAssertTrue(manager.hasPermission, "Reenable restores from the current shared snapshot")
        }
    }
}
