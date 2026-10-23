import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class SettingsOrganizationTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let domain = "app.notchx.tests.organization.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    func testLegacyMotionCombinationsAreSummarizedWithoutRewritingStoredValues() {
        for level in AnimationLevel.allCases {
            for motion in [false, true] {
                for effects in [false, true] {
                    let (defaults, domain) = preferences()
                    defer { defaults.removePersistentDomain(forName: domain) }
                    defaults.set(level.rawValue, forKey: SettingsDefaults.Appearance.animationLevel.key)
                    defaults.set(motion, forKey: SettingsDefaults.Appearance.reduceMotion.key)
                    defaults.set(effects, forKey: SettingsDefaults.Appearance.reduceAnimations.key)
                    defaults.set(0.73, forKey: "appearance.animationSpeed")
                    let before = defaults.persistentDomain(forName: domain)!
                    let state = AppState(preferenceStore: defaults)
                    let expected: AnimationLevel = motion || effects ? .reduced : level
                    XCTAssertEqual(state.manualMotionLevel, expected)
                    state.manualMotionLevel = expected
                    XCTAssertEqual(state.animationLevel, level)
                    XCTAssertEqual(state.reduceMotion, motion)
                    XCTAssertEqual(state.reduceAnimations, effects)
                    XCTAssertEqual(state.animationSpeed, 0.73)
                    XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
                }
            }
        }
    }

    func testExplicitMotionChoiceAndScopedRestoreUndoKeepTimingAndUnrelatedPreferences() {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0.73, forKey: "appearance.animationSpeed")
        defaults.set(217.3567, forKey: SettingsDefaults.Appearance.compactWidth.key)
        let state = AppState(preferenceStore: defaults)
        state.manualMotionLevel = .reduced
        XCTAssertTrue(state.reduceMotion)
        XCTAssertTrue(state.reduceAnimations)
        state.bounceAmount = 0.31
        let before = defaults.persistentDomain(forName: domain)!
        let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
        session.restoreGroup(.animation)
        XCTAssertEqual(state.manualMotionLevel, .full)
        XCTAssertFalse(state.reduceMotion)
        XCTAssertFalse(state.reduceAnimations)
        XCTAssertEqual(state.animationSpeed, 0.73)
        XCTAssertEqual(state.compactIslandWidth, 217.3567)
        session.undo(.animation)
        XCTAssertTrue(state.reduceAnimations)
        XCTAssertEqual(state.manualMotionLevel, .reduced)
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
        state.manualMotionLevel = .subtle
        XCTAssertFalse(state.reduceMotion)
        XCTAssertFalse(state.reduceAnimations)
        XCTAssertEqual(state.animationLevel, .subtle)
        XCTAssertEqual(state.bounceAmount, 0.31)
        XCTAssertEqual(state.animationSpeed, 0.73)
    }

    func testSameAppearanceIdentitySwitchesRestoreAndUndoToNewOwner() async throws {
        for (index, scope) in [SettingsRestoreScope.animation, .compactSize].enumerated() {
            let (defaultsA, domainA) = preferences()
            let (defaultsB, domainB) = preferences()
            defer { defaultsA.removePersistentDomain(forName: domainA); defaultsB.removePersistentDomain(forName: domainB) }
            let stateA = AppState(preferenceStore: defaultsA, preferenceDomainName: domainA)
            let stateB = AppState(preferenceStore: defaultsB, preferenceDomainName: domainB)
            stateA.manualMotionLevel = .reduced
            stateA.bounceAmount = 0.4
            stateA.compactIslandWidth = 217.25
            stateA.compactIslandHeight = 42.125
            stateB.manualMotionLevel = .subtle
            stateB.bounceAmount = 0.1
            stateB.compactIslandWidth = 263.5
            stateB.compactIslandHeight = 44.75
            stateB.animationSpeed = 0.73
            let savedB = defaultsB.persistentDomain(forName: domainB) ?? [:]
            let owner = AppearanceOwnerInput(state: stateA)
            let host = NSHostingView(rootView: SwitchingAppearanceHost(owner: owner).padding(24).notchXLocalized())
            let window = makeWindow(host: host, width: 740, height: 760)
            defer { window.contentView = nil; window.close() }
            try await NativeUI.waitFor("owner A appearance controls", in: host) { self.widthValue(in: host) == 217.25 }
            try pressAppearanceButton("Restore Group Defaults", index: index, in: host)
            try await NativeUI.waitFor("owner A appearance undo", in: host) { !self.appearanceButtons("Undo", in: host).isEmpty }
            let savedA = defaultsA.persistentDomain(forName: domainA) ?? [:]

            // Keep the same host/rootView and outer identity; only replace its input.
            owner.state = stateB
            try await NativeUI.waitFor("owner B appearance controls", in: host) { self.widthValue(in: host) == 263.5 }
            XCTAssertTrue(appearanceButtons("Undo", in: host).isEmpty, "Owner A's undo must not leak to B")
            try pressAppearanceButton("Restore Group Defaults", index: index, in: host)
            try await NativeUI.waitFor("owner B appearance restored", in: host) {
                switch scope {
                case .animation:
                    return stateB.manualMotionLevel == .full && !stateB.reduceMotion && !stateB.reduceAnimations && stateB.bounceAmount == 0.25
                case .compactSize:
                    return stateB.compactIslandWidth == 200 && stateB.compactIslandHeight == 36 && self.widthValue(in: host) == 200
                default: return false
                }
            }
            try await NativeUI.waitFor("owner B appearance undo", in: host) { !self.appearanceButtons("Undo", in: host).isEmpty }
            try pressAppearanceButton("Undo", in: host)
            try await NativeUI.waitFor("owner B appearance undone", in: host) {
                stateB.manualMotionLevel == .subtle && stateB.bounceAmount == 0.1 &&
                    stateB.compactIslandWidth == 263.5 && stateB.compactIslandHeight == 44.75 && self.widthValue(in: host) == 263.5
            }
            XCTAssertEqual(NSDictionary(dictionary: defaultsB.persistentDomain(forName: domainB) ?? [:]), NSDictionary(dictionary: savedB))
            XCTAssertEqual(NSDictionary(dictionary: defaultsA.persistentDomain(forName: domainA) ?? [:]), NSDictionary(dictionary: savedA))
            let reopenedB = AppState(preferenceStore: defaultsB, preferenceDomainName: domainB)
            XCTAssertEqual(reopenedB.manualMotionLevel, .subtle)
            XCTAssertEqual(reopenedB.bounceAmount, 0.1)
            XCTAssertEqual(reopenedB.compactIslandWidth, 263.5)
            XCTAssertEqual(reopenedB.compactIslandHeight, 44.75)

            owner.state = stateA
            try await NativeUI.waitFor("owner A appearance controls again", in: host) {
                self.widthValue(in: host) == (scope == .compactSize ? 200 : 217.25)
            }
            XCTAssertTrue(appearanceButtons("Undo", in: host).isEmpty, "Returning to A must not revive its old transaction")
            XCTAssertEqual(owner.appearances, 1)
        }
    }

    func testAppearanceControlsRestoreAndUndoUseExplicitOwnerDespiteForeignEnvironment() async throws {
        let (defaults, domain) = preferences()
        let (foreignDefaults, foreignDomain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain); foreignDefaults.removePersistentDomain(forName: foreignDomain) }
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        let foreign = AppState(preferenceStore: foreignDefaults, preferenceDomainName: foreignDomain)
        state.compactIslandWidth = 217.25
        state.compactIslandHeight = 42.125
        foreign.compactIslandWidth = 287.5
        let savedForeign = foreignDefaults.persistentDomain(forName: foreignDomain) ?? [:]
        let host = NSHostingView(rootView: AppearanceSettingsView(appState: state)
            .environmentObject(foreign).padding(24).notchXLocalized())
        let window = makeWindow(host: host, width: 740, height: 760)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("explicit appearance owner", in: host) { self.widthValue(in: host) == 217.25 }
        let slider = try XCTUnwrap(widthSlider(in: host))
        slider.setAccessibilityValue?(NSNumber(value: 250))
        try await NativeUI.waitFor("explicit owner's slider edit", in: host) { state.compactIslandWidth == 250 }
        let before = defaults.persistentDomain(forName: domain) ?? [:]
        try pressAppearanceButton("Restore Group Defaults", index: 1, in: host)
        try await NativeUI.waitFor("explicit owner's size restored", in: host) { state.compactIslandWidth == 200 && state.compactIslandHeight == 36 }
        try await NativeUI.waitFor("explicit owner's undo", in: host) { !self.appearanceButtons("Undo", in: host).isEmpty }
        try pressAppearanceButton("Undo", in: host)
        try await NativeUI.waitFor("explicit owner's size undone", in: host) { state.compactIslandWidth == 250 && state.compactIslandHeight == 42.125 }
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]), NSDictionary(dictionary: before))
        XCTAssertEqual(foreign.compactIslandWidth, 287.5)
        XCTAssertEqual(NSDictionary(dictionary: foreignDefaults.persistentDomain(forName: foreignDomain) ?? [:]), NSDictionary(dictionary: savedForeign))
    }

    func testAllSettingsPagesFitBothLanguagesAndWidthsWithoutChangingPreferences() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        for module in ModuleType.allCases { defaults.set(true, forKey: "module.\(module.rawValue).enabled") }
        for event in IslandEventKind.allCases { defaults.set(13.75, forKey: event.durationKey) }
        defaults.set(2.375, forKey: "general.expandedAutoDismissDelay")
        defaults.set(0.2375, forKey: "general.hoverExpandDelay")
        defaults.set("disconnected-saved-display", forKey: "general.displayIdentifier")
        let state = AppState(preferenceStore: defaults)
        let before = defaults.persistentDomain(forName: domain)!
        let navigation = SettingsNavigation.shared
        let oldPane = navigation.selectedPane
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            navigation.selectedPane = oldPane
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let panes: [SettingsPane] = [.general, .modules, .home, .appearance, .advanced] + ModuleType.allCases.map(SettingsPane.module)
        for language in ["zh-Hans", "en"] {
            // Process-local arguments override localization without writing the user's preference.
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for width: CGFloat in [800, 1100] {
                let host = NSHostingView(rootView: SettingsView().environmentObject(state))
                let window = makeWindow(host: host, width: width, height: 680)
                defer { window.close() }
                for pane in panes {
                    // The app reuses its settings window; do not start 60 native
                    // window animations while checking page/control geometry.
                    window.makeFirstResponder(nil)
                    navigation.selectedPane = pane
                    try await waitForPage(pane, in: host)
                    let collapsed = accessibilityElements(in: host)
                    for disclosure in collapsed where disclosure.accessibilityRole?() == .disclosureTriangle {
                        _ = disclosure.accessibilityPerformPress?()
                    }
                    if collapsed.contains(where: { $0.accessibilityRole?() == .disclosureTriangle }) {
                        try await NativeUI.waitFor("page disclosures expanded", in: host) {
                            let disclosures = self.accessibilityElements(in: host).filter { $0.accessibilityRole?() == .disclosureTriangle }
                            return !disclosures.isEmpty && disclosures.allSatisfy { disclosure in
                                let value: (() -> Any?)? = disclosure.accessibilityValue
                                return (value?() as? NSNumber)?.intValue == 1
                            }
                        }
                    }
                    let elements = accessibilityElements(in: host)
                    XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "settings-page-title" }, "Missing page title: \(pane.id)")
                    let controls: [NSAccessibility.Role] = [.button, .popUpButton, .checkBox, .slider, .radioButton, .textField]
                    for element in elements {
                        guard let role = element.accessibilityRole?(), controls.contains(role),
                              let frame = element.accessibilityFrame?(), frame.width > 0 else { continue }
                        XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 2, "\(language) \(width) \(pane.id): left-clipped control")
                        XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 2, "\(language) \(width) \(pane.id): right-clipped control")
                    }
                    let labels = elements.filter { $0.accessibilityIdentifier?()?.hasPrefix("settings-label-") == true }
                    if let left = labels.first?.accessibilityFrame?().minX {
                        for label in labels {
                            XCTAssertEqual(try XCTUnwrap(label.accessibilityFrame?()).minX, left, accuracy: 1,
                                           "\(language) \(width) \(pane.id): row label alignment")
                        }
                    }
                    if pane == .module(.volumeHUD) {
                        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "volume-output-device" })
                        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "volume-mute" })
                        XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "event-duration-volume" })
                    }
                    if pane == .general {
                        for id in ["settings-collapse-delay", "settings-hover-delay"] {
                            XCTAssertEqual(elements.first { $0.accessibilityIdentifier?() == id + "-slider" }?.accessibilityRole?(), .slider)
                            XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == id + "-stepper" })
                        }
                    }
                    if case .module(let module) = pane {
                        for event in IslandEventKind.allCases where event.module == module {
                            let id = "event-duration-" + event.rawValue
                            XCTAssertEqual(elements.first { $0.accessibilityIdentifier?() == id + "-slider" }?.accessibilityRole?(), .slider)
                            XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == id + "-stepper" })
                        }
                    }
                    if pane == .module(.calendar) {
                        XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "settings-calendar-lead-time-stepper" })
                        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "settings-calendar-lead-time-slider" })
                    }
                    if pane == .module(.teleprompter) {
                        XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "settings-teleprompter-countdown-stepper" })
                        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "settings-teleprompter-countdown-slider" })
                    }
                    if pane == .module(.notifications) {
                        XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "settings-notification-previews" })
                    }
                }
            }
        }
        for event in IslandEventKind.allCases { XCTAssertEqual(state.presentationPreferences[event].duration, 13.75) }
        XCTAssertEqual(state.expandedAutoDismissDelay, 2.375)
        XCTAssertEqual(state.hoverExpandDelay, 0.2375)
        XCTAssertEqual(state.displayIdentifier, "disconnected-saved-display")
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
    }

    func testDefaultAndCustomEventDurationsUseTheSameDirectEditor() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        // Both a default value and an existing fractional preference remain directly editable.
        for duration in [IslandEventKind.volume.defaultDuration, 13.75] {
            state.presentationPreferences[.volume].duration = duration
            let before = defaults.persistentDomain(forName: domain) ?? [:]
            let host = NSHostingView(rootView: IslandEventSettings(module: .volumeHUD).environmentObject(state))
            let window = makeWindow(host: host, width: 520, height: 280)
            _ = try await NativeUI.waitForElement(in: host, id: "event-duration-volume")
            let elements = accessibilityElements(in: host)
            let field = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == "event-duration-volume" })
            XCTAssertEqual(field.accessibilityRole?(), .textField)
            XCTAssertEqual(elements.first { $0.accessibilityIdentifier?() == "event-duration-volume-slider" }?.accessibilityRole?(), .slider)
            XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "event-duration-volume-stepper" })
            XCTAssertFalse(elements.contains { $0.accessibilityRole?() == .popUpButton })
            XCTAssertFalse(elements.contains { $0.accessibilityLabel?() == L10n.text("Preview") })
            window.close()
            XCTAssertEqual(state.presentationPreferences[.volume].duration, duration)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]), NSDictionary(dictionary: before))
        }
    }

    func testProductionTimingSlidersUseTheirPurposeSpecificCommonRanges() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let navigation = SettingsNavigation.shared
        let previousPane = navigation.selectedPane
        defer { navigation.selectedPane = previousPane }
        let eventRanges: [IslandEventKind: ClosedRange<Double>] = [
            .volume: 1...5, .powerChanged: 1...5, .batteryFull: 1...5,
            .bluetoothConnected: 1...5, .bluetoothDisconnected: 1...5,
            .lowBattery: 1...10, .notification: 1...10, .calendarReminder: 1...15
        ]
        let host = NSHostingView(rootView: SettingsView().environmentObject(state))
        let window = makeWindow(host: host, width: 1100, height: 680)
        defer { window.close() }
        let panes: [SettingsPane] = [.general] + [ModuleType.volumeHUD, .battery, .connectivity, .calendar, .notifications].map(SettingsPane.module)
        for pane in panes {
            navigation.selectedPane = pane
            try await waitForPage(pane, in: host)
            let elements = accessibilityElements(in: host)
            func moveToMiddle(_ id: String) async throws {
                let slider = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id + "-slider" })
                let minimum = try XCTUnwrap(slider.accessibilityMinValue?() as? NSNumber).doubleValue
                let maximum = try XCTUnwrap(slider.accessibilityMaxValue?() as? NSNumber).doubleValue
                slider.setAccessibilityValue?(NSNumber(value: (minimum + maximum) / 2))
                await NativeUI.drainMainQueue()
            }
            if pane == .general {
                try await moveToMiddle("settings-collapse-delay")
                XCTAssertEqual(state.expandedAutoDismissDelay, 1.55, accuracy: 0.000001)
                try await moveToMiddle("settings-hover-delay")
                XCTAssertEqual(state.hoverExpandDelay, 0.5, accuracy: 0.000001)
            } else if case .module(let module) = pane {
                for event in IslandEventKind.allCases where event.module == module {
                    let range = try XCTUnwrap(eventRanges[event])
                    let oldValue = state.presentationPreferences[event].duration
                    XCTAssertEqual(oldValue, event.defaultDuration)
                    try await moveToMiddle("event-duration-" + event.rawValue)
                    XCTAssertEqual(state.presentationPreferences[event].duration, (range.lowerBound + range.upperBound) / 2,
                                   accuracy: 0.000001, event.rawValue)
                }
            }
        }
    }

    func testEventDisplayToggleHidesTimingWithoutDiscardingItsCustomValue() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        state.presentationPreferences[.volume].duration = 13.75
        let host = NSHostingView(rootView: IslandEventSettings(module: .volumeHUD).environmentObject(state))
        let window = makeWindow(host: host, width: 520, height: 280)
        defer { window.close() }
        let toggle = try await NativeUI.waitForElement(in: host, id: "event-enabled-volume")
        XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("event timing hidden", in: host) {
            !state.presentationPreferences[.volume].enabled && NativeUI.find(in: host, id: "event-duration-volume") == nil
        }
        XCTAssertFalse(state.presentationPreferences[.volume].enabled)
        XCTAssertNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume" })
        XCTAssertNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume-slider" })
        XCTAssertEqual(state.presentationPreferences[.volume].duration, 13.75)
        let disabledToggle = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-enabled-volume" })
        XCTAssertEqual(disabledToggle.accessibilityPerformPress?(), true)
        _ = try await NativeUI.waitForElement(in: host, id: "event-duration-volume")
        XCTAssertTrue(state.presentationPreferences[.volume].enabled)
        XCTAssertNotNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume" })
        XCTAssertNotNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume-slider" })
        XCTAssertEqual(state.presentationPreferences[.volume].duration, 13.75)
    }

    func testModuleHeaderSwitchKeepsPreferencesAndRevealsTheSameSettings() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(13.7567, forKey: IslandEventKind.volume.durationKey)
        defaults.set("keep-other-module", forKey: "test.unrelated")
        let before = defaults.persistentDomain(forName: domain) ?? [:]
        let state = AppState(preferenceStore: defaults)
        let host = NSHostingView(rootView: ModuleDetailSettingsView(module: .volumeHUD, appState: state).environmentObject(state))
        let window = makeWindow(host: host, width: 520, height: 680)
        defer { window.close() }
        _ = try await NativeUI.waitForElement(in: host, id: "event-duration-volume")
        func toggle() throws -> AnyObject {
            try XCTUnwrap(accessibilityElements(in: host).first {
                $0.accessibilityIdentifier?() == "data-annotation-id=module-detail-toggle-volumeHUD"
            })
        }
        XCTAssertEqual(try toggle().accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("module settings hidden", in: host) {
            !state.volumeHUDEnabled && NativeUI.find(in: host, id: "event-duration-volume") == nil
        }
        XCTAssertFalse(state.volumeHUDEnabled)
        XCTAssertNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume" })
        XCTAssertEqual(state.presentationPreferences[.volume].duration, 13.7567)
        XCTAssertEqual(try toggle().accessibilityPerformPress?(), true)
        _ = try await NativeUI.waitForElement(in: host, id: "event-duration-volume")
        XCTAssertTrue(state.volumeHUDEnabled)
        XCTAssertNotNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "event-duration-volume" })
        XCTAssertEqual(state.presentationPreferences[.volume].duration, 13.7567)
        var after = defaults.persistentDomain(forName: domain) ?? [:]
        after.removeValue(forKey: "module.volumeHUD.enabled")
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: before))
    }

    func testFeedPauseControlsWorkWithoutNotificationsAndResumeKeepsTheFeed() async throws {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let manager = NotificationManager(state: state, observesSystemEvents: false, presentNotification: {})
        manager.pauseAlerts(for: 1800)
        let host = NSHostingView(rootView: NotificationAlertControls(manager: manager))
        let window = makeWindow(host: host, width: 520, height: 80)
        defer { window.close() }
        _ = try await NativeUI.waitForElement(in: host, id: "notification-resume-alerts")
        XCTAssertNotNil(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "notification-pause-alerts" })
        let resume = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "notification-resume-alerts" })
        XCTAssertEqual(resume.accessibilityPerformPress?(), true)
        XCTAssertFalse(manager.alertsArePaused)
        XCTAssertTrue(manager.recentNotifications.isEmpty)
    }

    private func waitForPage(_ pane: SettingsPane, in host: NSView) async throws {
        try await NativeUI.waitFor("settings page \(pane.id)", in: host) {
            guard let title = NativeUI.find(in: host, id: "settings-page-title") else { return false }
            let value: (() -> Any?)? = title.accessibilityValue
            return (value?() as? String ?? title.accessibilityLabel?()) == pane.title
        }
        // Let the selected page's queued SwiftUI update finish before inspecting
        // controls; a title belonging to the previous page is never sufficient.
        await NativeUI.drainMainQueue()
        host.layoutSubtreeIfNeeded()
    }

    private func appearanceButtons(_ title: String, in root: Any) -> [AnyObject] {
        NativeUI.elements(in: root).filter { $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == L10n.text(title) }
    }

    private func pressAppearanceButton(_ title: String, index: Int = 0, in root: Any) throws {
        let button = try XCTUnwrap(appearanceButtons(title, in: root).dropFirst(index).first)
        XCTAssertEqual(button.accessibilityPerformPress?(), true)
    }

    private func widthSlider(in root: Any) -> AnyObject? {
        NativeUI.elements(in: root).first { $0.accessibilityRole?() == .slider && $0.accessibilityLabel?() == L10n.text("Width") }
    }

    private func widthValue(in root: Any) -> Double? {
        guard let slider = widthSlider(in: root) else { return nil }
        let value: Any? = slider.accessibilityValue?()
        return (value as? NSNumber)?.doubleValue
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func accessibilityElements(in root: Any, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let element = root as AnyObject
        return [element] + (element.accessibilityChildren?() ?? []).flatMap { accessibilityElements(in: $0, depth: depth + 1) }
    }
}

@MainActor
private final class AppearanceOwnerInput: ObservableObject {
    @Published var state: AppState
    var appearances = 0
    init(state: AppState) { self.state = state }
}

private struct SwitchingAppearanceHost: View {
    @ObservedObject var owner: AppearanceOwnerInput
    var body: some View {
        AppearanceSettingsView(appState: owner.state)
            .environmentObject(owner.state)
            .onAppear { owner.appearances += 1 }
    }
}
