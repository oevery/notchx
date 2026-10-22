import XCTest
@testable import NotchX

@MainActor
final class StagedEnhancementTests: XCTestCase {
    private func withState(_ body: (AppState, UserDefaults, String) throws -> Void) rethrows {
        let domain = "app.notchx.tests.enhancements.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer { state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); defaults.removePersistentDomain(forName: domain) }
        try body(state, defaults, domain)
    }

    func testAutomaticEventsCanBeDisabledWithoutDisablingTheModuleAndPersistIndependently() {
        withState { state, defaults, _ in
            state.presentationPreferences[.volume].enabled = false
            state.presentationPreferences[.lowBattery].duration = 12
            state.presentEvent(.volume)
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertTrue(state.volumeHUDEnabled)
            let reopened = AppState(preferenceStore: defaults)
            XCTAssertFalse(reopened.presentationPreferences[.volume].enabled)
            XCTAssertEqual(reopened.presentationPreferences[.lowBattery].duration, 12)
            XCTAssertTrue(reopened.presentationPreferences[.powerChanged].enabled)
        }
    }

    func testRemindersDoNotNavigateHeldTeleprompterAndExplicitPendingSelectionWorks() {
        withState { state, _, _ in
            state.teleprompterEnabled = true
            state.setActiveModule(.teleprompter, userInitiated: true)
            state.holdPresentation(for: .builtIn(.teleprompter))
            state.presentEvent(.calendarReminder)
            state.presentEvent(.calendarReminder)
            state.presentEvent(.notification)
            state.presentEvent(.volume)
            XCTAssertEqual(state.activeModule, .builtIn(.teleprompter))
            XCTAssertEqual(state.pendingIslandEvents, [.calendarReminder, .notification])
            state.viewPendingEvent(.calendarReminder)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.calendar)))
            XCTAssertEqual(state.pendingIslandEvents, [.notification])
            state.releasePresentationHold(for: .builtIn(.teleprompter))
        }
    }

    func testOpenWorkspaceAndControlInteractionKeepTheirSelection() {
        withState { state, _, _ in
            state.currentState = .fullExpanded
            state.selectFullExpandedTab(.module(.builtIn(.weather)))
            state.presentEvent(.calendarReminder)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.weather)))
            state.dismiss()
            let interaction = state.beginControlInteraction()
            state.presentEvent(.notification)
            XCTAssertEqual(state.currentState, .compact)
            state.endControlInteraction(interaction)
            XCTAssertEqual(Set(state.pendingIslandEvents), [.calendarReminder, .notification])
            state.notificationMaxRetainedItems = 3
        }
    }

    func testVisibleRemindersDoNotCreatePendingBadgesAndDisableClearsPending() {
        withState { state, _, _ in
            state.selectFullExpandedTab(.module(.builtIn(.calendar)))
            state.currentState = .fullExpanded
            state.presentEvent(.calendarReminder)
            XCTAssertTrue(state.pendingIslandEvents.isEmpty)
            state.selectFullExpandedTab(.module(.builtIn(.weather)))
            state.presentEvent(.calendarReminder)
            XCTAssertEqual(state.pendingIslandEvents, [.calendarReminder])
            state.setModuleEnabled(.calendar, enabled: false)
            XCTAssertTrue(state.pendingIslandEvents.isEmpty)
            state.presentEvent(.calendarReminder)
            XCTAssertTrue(state.pendingIslandEvents.isEmpty)
        }
    }

    func testVolumeDetailsAreAvailableWithoutAddingVolumeToCycling() {
        withState { state, _, _ in
            XCTAssertTrue(state.canPresentFullExpandedModule(.builtIn(.volumeHUD)))
            XCTAssertFalse(state.fullExpandedModules.contains(.builtIn(.volumeHUD)))
            state.selectFullExpandedTab(.module(.builtIn(.volumeHUD)))
            state.reconcileEnabledModules()
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.volumeHUD)))
            state.setModuleEnabled(.volumeHUD, enabled: false)
            state.reconcileEnabledModules()
            XCTAssertFalse(state.canPresentFullExpandedModule(.builtIn(.volumeHUD)))
            XCTAssertEqual(state.fullExpandedSelectedTab, .home)
        }
    }

    func testIdleChoiceRespectsDisabledModulesAndDoesNotChangeNavigationOrder() {
        withState { state, _, _ in
            state.nowPlayingEnabled = false
            let order = state.orderedModules
            state.presentationPreferences.idleContent = .weather
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.weather))
            state.weatherEnabled = false
            XCTAssertNil(state.compactPresentationModule)
            state.presentationPreferences.idleContent = .calendar
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.calendar))
            state.presentationPreferences.idleContent = .none
            XCTAssertNil(state.compactPresentationModule)
            XCTAssertEqual(state.orderedModules, order)
        }
    }

    func testModuleRestoreResetsOnlyItsEventPreferencesAndKeepsOtherPolicies() {
        withState { state, defaults, domain in
            state.presentationPreferences[.volume].enabled = false
            state.presentationPreferences[.lowBattery].enabled = false
            state.presentationPreferences.idleContent = .weather
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.requestModuleRestore(.volumeHUD)
            session.confirmModuleRestore()
            XCTAssertTrue(state.presentationPreferences[.volume].enabled)
            XCTAssertFalse(state.presentationPreferences[.lowBattery].enabled)
            XCTAssertEqual(state.presentationPreferences.idleContent, .weather)
            XCTAssertTrue(state.volumeHUDEnabled)
        }
    }

    func testBatteryEventsDistinguishLowPowerFullAndPlugChangesWithoutStartupAlert() {
        let discharging = BatteryPowerSnapshot(level: 21, charging: false, pluggedIn: false)
        let low = BatteryPowerSnapshot(level: 20, charging: false, pluggedIn: false)
        XCTAssertNil(low.event(after: nil, lowThreshold: 20))
        XCTAssertEqual(low.event(after: discharging, lowThreshold: 20), .lowBattery)
        XCTAssertNil(low.event(after: low, lowThreshold: 20))
        let paused = BatteryPowerSnapshot(level: 80, charging: false, pluggedIn: true)
        XCTAssertEqual(paused.event(after: low, lowThreshold: 20), .powerChanged)
        XCTAssertEqual(paused.status, L10n.text("Connected, not charging"))
        let full = BatteryPowerSnapshot(level: 100, charging: false, pluggedIn: true)
        XCTAssertEqual(full.event(after: paused, lowThreshold: 20), .batteryFull)
        XCTAssertNil(full.event(after: full, lowThreshold: 20))
    }
}
