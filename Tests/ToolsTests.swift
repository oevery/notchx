import XCTest
import SwiftUI
import AppKit
@testable import NotchX

@MainActor
private final class TestAwakeAssertion: KeepAwakeAsserting {
    var acquireSucceeds = true
    var releaseSucceeds = true
    var acquisitions = 0
    var releases = 0
    func acquire() -> Bool { acquisitions += 1; return acquireSucceeds }
    func release() -> Bool { releases += 1; return releaseSucceeds }
}

@MainActor
private final class TestKeyboardBlocker: KeyboardInputBlocking {
    var hasAccessibility = true
    var hasPressedKeys = false
    var isHealthy = true
    var startSucceeds = true
    var starts = 0
    var stops = 0
    var interrupted: (() -> Void)?
    func start(onInterruption: @escaping () -> Void) -> Bool {
        starts += 1
        interrupted = onInterruption
        return startSucceeds
    }
    func stop() { stops += 1 }
}

@MainActor
final class ToolsTests: XCTestCase {
    private func withTools(_ body: (ToolsManager, AppState, TestAwakeAssertion, TestKeyboardBlocker, (TimeInterval) -> Void) throws -> Void) rethrows {
        let domain = "app.notchx.tests.tools." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        let assertion = TestAwakeAssertion(), keyboard = TestKeyboardBlocker()
        var clock: TimeInterval = 100
        let manager = ToolsManager(assertion: assertion, keyboard: keyboard, uptime: { clock },
                                   appState: { state }, monitorsSystem: false)
        manager.setEnabled(true)
        defer {
            assertion.releaseSucceeds = true
            manager.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            state.endSystemEmojiInteraction()
            defaults.removePersistentDomain(forName: domain)
        }
        try body(manager, state, assertion, keyboard, { clock += $0 })
    }

    private func withToolsAsync(_ body: (ToolsManager, AppState, TestKeyboardBlocker) async throws -> Void) async throws {
        let domain = "app.notchx.tests.tools-layout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        let assertion = TestAwakeAssertion(), keyboard = TestKeyboardBlocker()
        let manager = ToolsManager(assertion: assertion, keyboard: keyboard, appState: { state }, monitorsSystem: false)
        manager.setEnabled(true)
        defer {
            manager.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            state.endSystemEmojiInteraction()
            defaults.removePersistentDomain(forName: domain)
        }
        try await body(manager, state, keyboard)
    }

    func testAwakeCountdownExpiresEachSupportedDurationAndReleasesAssertion() {
        for duration in KeepAwakeDuration.allCases where duration != .forever {
            withTools { manager, state, assertion, _, advance in
                manager.startKeepingAwake(for: duration)
                manager.startKeepingAwake(for: duration)
                XCTAssertEqual(assertion.acquisitions, 1)
                XCTAssertTrue(manager.isKeepingAwake && state.isKeepAwakeActive)
                let seconds = duration.seconds(customMinutes: state.keepAwakeCustomMinutes)!
                XCTAssertEqual(manager.awakeRemaining, seconds)
                advance(seconds - 1)
                manager.checkAwakeExpiry()
                XCTAssertTrue(manager.isKeepingAwake)
                XCTAssertEqual(ToolsManager.countdownText(manager.awakeRemaining), "00:01")
                advance(2)
                manager.checkAwakeExpiry()
                XCTAssertFalse(manager.isKeepingAwake || state.isKeepAwakeActive)
                XCTAssertEqual(assertion.releases, 1)
            }
        }
    }

    func testAwakeFailuresNeverInventSuccessAndManualStopClearsDeadline() {
        withTools { manager, state, assertion, _, advance in
            assertion.acquireSucceeds = false
            manager.startKeepingAwake(for: .thirtyMinutes)
            XCTAssertFalse(manager.isKeepingAwake || state.isKeepAwakeActive)
            XCTAssertNotNil(manager.awakeError)
            assertion.acquireSucceeds = true
            manager.startKeepingAwake(for: .fifteenMinutes)
            assertion.releaseSucceeds = false
            manager.stopKeepingAwake()
            XCTAssertTrue(manager.isKeepingAwake && state.isKeepAwakeActive)
            XCTAssertNotNil(manager.awakeError)
            assertion.releaseSucceeds = true
            manager.stopKeepingAwake()
            advance(10_000)
            manager.checkAwakeExpiry()
            XCTAssertFalse(manager.isKeepingAwake || state.isKeepAwakeActive)
            XCTAssertEqual(manager.awakeRemaining, 0)
        }
    }

    func testFailedDisableDoesNotHideAnUnreleasedIndefiniteAssertion() {
        withTools { manager, state, assertion, _, _ in
            manager.startKeepingAwake(for: .forever)
            assertion.releaseSucceeds = false
            manager.setEnabled(false)
            XCTAssertTrue(manager.isEnabled, "A failed resource release must not masquerade as a stopped module")
            XCTAssertTrue(manager.isKeepingAwake && state.isKeepAwakeActive)
            XCTAssertNotNil(manager.awakeError)
            assertion.releaseSucceeds = true
            manager.setEnabled(false)
            XCTAssertFalse(manager.isEnabled || manager.isKeepingAwake || state.isKeepAwakeActive)
        }
    }

    func testFailedToolsStopRejectsTheSettingChangeAndAllowsExplicitRetry() {
        withTools { manager, state, assertion, _, _ in
            state.moduleEnablementWillChange = { module, enabled in module != .tools || enabled || manager.setEnabled(false) }
            state.moduleEnablementDidChange = { manager.setEnabled(state.toolsEnabled) }
            defer { state.moduleEnablementWillChange = nil; state.moduleEnablementDidChange = nil }
            manager.startKeepingAwake(for: .forever)
            assertion.releaseSucceeds = false
            state.setModuleEnabled(.tools, enabled: false)
            XCTAssertTrue(state.toolsEnabled && manager.isEnabled && manager.isKeepingAwake)
            XCTAssertNotNil(manager.awakeError)
            assertion.releaseSucceeds = true
            state.setModuleEnabled(.tools, enabled: false)
            XCTAssertFalse(state.toolsEnabled || manager.isEnabled || manager.isKeepingAwake || state.isKeepAwakeActive)
        }
    }

    func testSettingsKeepsFailedStopVisibleAndItsRetryUsesTheSameLifecycleEntry() async throws {
        let domain = "app.notchx.tests.tools-stop-retry." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        let assertion = TestAwakeAssertion()
        let runtime = ToolsManager(assertion: assertion, keyboard: TestKeyboardBlocker(), appState: { state }, monitorsSystem: false)
        runtime.setEnabled(true)
        defer {
            assertion.releaseSucceeds = true; runtime.setEnabled(false)
            state.moduleEnablementWillChange = nil
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            defaults.removePersistentDomain(forName: domain)
        }
        state.moduleEnablementWillChange = { module, enabled in module != .tools || enabled || runtime.setEnabled(false) }
        runtime.startKeepingAwake(for: .forever)
        assertion.releaseSucceeds = false
        state.setModuleEnabled(.tools, enabled: false)
        let host = NSHostingView(rootView: ToolsSettingsDetail(manager: runtime).environmentObject(state).frame(width: 700))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let retry = try await NativeUI.waitForElement(in: host, id: "tools-stop-retry")
        XCTAssertTrue(state.toolsEnabled && runtime.isKeepingAwake)
        assertion.releaseSucceeds = true
        XCTAssertEqual(retry.accessibilityPerformPress?(), true)
        XCTAssertFalse(state.toolsEnabled || runtime.isKeepingAwake)
    }

    func testCountdownNeverExceedsFiveCharactersAndOmitsSecondsForLongSessions() {
        XCTAssertEqual(ToolsManager.countdownText(3600), "1:00")
        XCTAssertEqual(ToolsManager.countdownText(7200), "2:00")
        XCTAssertEqual(ToolsManager.countdownText(3601), "1:01")
        XCTAssertEqual(ToolsManager.countdownText(86400), "24:00")
        XCTAssertEqual(ToolsManager.countdownText(1799.2), "30:00")
        XCTAssertEqual(ToolsManager.countdownText(0.1), "00:01")
        XCTAssertEqual(ToolsManager.countdownText(-1), "00:00")
        XCTAssertTrue((0...86400).allSatisfy { ToolsManager.countdownText(Double($0)).count <= 5 })
    }

    func testForeverDoesNotExpireAndOnlyReleasesOnManualStopOrDisable() {
        withTools { manager, state, assertion, _, advance in
            manager.startKeepingAwake(for: .forever)
            advance(1_000_000)
            manager.checkAwakeExpiry()
            XCTAssertTrue(manager.isKeepingAwake && manager.isAwakeIndefinite && state.isKeepAwakeActive)
            XCTAssertEqual(assertion.releases, 0)
            XCTAssertEqual(manager.awakeRemainingDescription, L10n.text("Until turned off"))
            manager.stopKeepingAwake()
            XCTAssertEqual(assertion.releases, 1)
            XCTAssertFalse(manager.isAwakeIndefinite || state.isKeepAwakeActive)
        }
    }

    func testCustomTimeIsBoundedAndEditingDefaultsDoesNotChangeRunningDeadline() {
        withTools { manager, state, _, _, advance in
            state.keepAwakeCustomMinutes = -10
            XCTAssertEqual(state.keepAwakeCustomMinutes, 1)
            state.keepAwakeCustomMinutes = 2000
            XCTAssertEqual(state.keepAwakeCustomMinutes, 1440)
            state.keepAwakeCustomMinutes = .nan
            XCTAssertEqual(state.keepAwakeCustomMinutes, 90)
            state.keepAwakeCustomMinutes = 75
            state.keepAwakeDuration = .custom
            let reloaded = AppState(preferenceStore: state.modulePreferenceStore)
            XCTAssertEqual(reloaded.keepAwakeDuration, .custom)
            XCTAssertEqual(reloaded.keepAwakeCustomMinutes, 75)
            manager.startKeepingAwake(for: state.keepAwakeDuration)
            XCTAssertEqual(manager.awakeRemaining, 4500)
            state.keepAwakeCustomMinutes = 5
            state.keepAwakeDuration = .forever
            advance(4499)
            XCTAssertEqual(manager.awakeRemaining, 1)
            manager.checkAwakeExpiry()
            XCTAssertTrue(manager.isKeepingAwake)
            advance(1)
            manager.checkAwakeExpiry()
            XCTAssertFalse(manager.isKeepingAwake)
        }
    }

    func testToolsRestorePreservesRunningWakeSessionAndModuleEnablement() {
        let domain = "app.notchx.tests.tools-restore." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        let assertion = TestAwakeAssertion(), keyboard = TestKeyboardBlocker()
        let manager = ToolsManager(assertion: assertion, keyboard: keyboard, uptime: { 100 }, appState: { state }, monitorsSystem: false)
        defer { manager.setEnabled(false); defaults.removePersistentDomain(forName: domain) }
        manager.setEnabled(true)
        state.keepAwakeDuration = .custom
        state.keepAwakeCustomMinutes = 135
        manager.startKeepingAwake(for: .custom)
        let restore = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
        restore.requestModuleRestore(.tools)
        XCTAssertEqual(state.keepAwakeDuration, .custom)
        restore.cancelModuleRestore()
        XCTAssertEqual(state.keepAwakeCustomMinutes, 135)
        restore.requestModuleRestore(.tools)
        restore.confirmModuleRestore()
        XCTAssertEqual(state.keepAwakeDuration, .thirtyMinutes)
        XCTAssertEqual(state.keepAwakeCustomMinutes, 90)
        XCTAssertTrue(state.toolsEnabled && manager.isKeepingAwake)
        XCTAssertEqual(manager.awakeRemaining, 8100)
        XCTAssertEqual(assertion.acquisitions, 1)
        XCTAssertFalse(restore.canUndo(.module(.tools)))
    }

    func testCleaningFailureDoesNotLockOrHoldTheIsland() {
        withTools { manager, state, _, keyboard, _ in
            keyboard.hasAccessibility = false
            manager.startCleaning()
            XCTAssertEqual(keyboard.starts, 0)
            keyboard.hasAccessibility = true
            keyboard.hasPressedKeys = true
            manager.startCleaning()
            XCTAssertEqual(keyboard.starts, 0)
            keyboard.hasPressedKeys = false
            keyboard.startSucceeds = false
            manager.startCleaning()
            XCTAssertEqual(keyboard.starts, 1)
            XCTAssertEqual(manager.cleaningState, .idle)
            XCTAssertFalse(state.isKeyboardCleaningActive || state.isControlInteractionActive)
            XCTAssertNotNil(manager.cleaningError)
        }
    }

    func testCleaningHasNoDeadlineAndProtectsTheEndButtonFromNavigationAndEvents() {
        withTools { manager, state, _, keyboard, advance in
            manager.startCleaning()
            advance(100_000)
            manager.checkCleaningHealth()
            state.handleHoverChange(false)
            state.dismiss()
            state.showHomeTab()
            state.presentNowPlaying()
            state.setActiveModule(.calendar, userInitiated: true)
            state.selectFullExpandedTab(.home)
            state.cycleModule(forward: true)
            state.showHUD(module: .volumeHUD, autoDismiss: false)
            state.presentEvent(.volume)
            state.presentShelfAfterDrop()
            state.beginShelfDragPresentation(owner: UUID())
            XCTAssertNil(state.beginPresentationHandoff(.window))
            XCTAssertEqual(manager.cleaningState, .locked)
            XCTAssertEqual(keyboard.stops, 0)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.tools)))
            XCTAssertFalse(state.canHandleIslandSurfaceGesture)
            manager.endCleaning()
            XCTAssertEqual(manager.cleaningState, .idle)
            XCTAssertEqual(keyboard.stops, 1)
            XCTAssertFalse(state.isKeyboardCleaningActive || state.isControlInteractionActive)
            state.selectFullExpandedTab(.home)
            XCTAssertEqual(state.fullExpandedSelectedTab, .home)
        }
    }

    func testMouseExitWaitsForHeldKeysAndStaleInterruptionCannotEndANewSession() {
        withTools { manager, state, _, keyboard, _ in
            manager.startCleaning()
            let stale = keyboard.interrupted
            keyboard.hasPressedKeys = true
            manager.endCleaning()
            XCTAssertEqual(manager.cleaningState, .releasing)
            manager.checkCleaningHealth()
            XCTAssertTrue(state.isKeyboardCleaningActive)
            keyboard.hasPressedKeys = false
            manager.checkCleaningHealth()
            XCTAssertEqual(manager.cleaningState, .idle)
            manager.startCleaning()
            stale?()
            XCTAssertEqual(manager.cleaningState, .locked)
            keyboard.isHealthy = false
            manager.checkCleaningHealth()
            XCTAssertEqual(manager.cleaningState, .idle)
            XCTAssertNotNil(manager.cleaningError)
            XCTAssertFalse(state.isKeyboardCleaningActive)
        }
    }

    func testDisableStopsBothToolsAndCannotRestartUntilReenabled() {
        withTools { manager, state, assertion, keyboard, _ in
            manager.startKeepingAwake(for: .sixtyMinutes)
            manager.startCleaning()
            manager.setEnabled(false)
            XCTAssertEqual(assertion.releases, 1)
            XCTAssertEqual(keyboard.stops, 1)
            XCTAssertFalse(state.isKeyboardCleaningActive || state.isKeepAwakeActive)
            manager.startCleaning()
            manager.startKeepingAwake(for: .thirtyMinutes)
            XCTAssertEqual(assertion.acquisitions, 1)
            XCTAssertEqual(keyboard.starts, 1)
        }
    }

    func testAwakeUsesMusicSideSlotGeometryAndRestoresIdleContentOnStop() {
        withTools { manager, state, _, _, _ in
            state.presentationPreferences.idleContent = .battery
            state.agentEnabled = false
            state.nowPlayingEnabled = false
            state.updatePresentationContext(screen: nil)
            manager.startKeepingAwake(for: .thirtyMinutes)
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.tools))
            XCTAssertTrue(state.fullExpandedTabs.contains(.module(.builtIn(.tools))))
            manager.stopKeepingAwake()
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
        }
    }

    func testAwakeActivityKeepsAgentAttentionAndOpenPagePriority() {
        func resolve(attention: Bool, compact: Bool) -> ActiveModule? {
            CompactModuleSelection.resolve(active: .builtIn(.calendar),
                explicitSelection: .builtIn(.calendar), presentationHold: nil,
                hasVerifiedAgentAttention: attention, hasMedia: true, mediaIsPlaying: true,
                batteryEnabled: true, isCompact: compact, isKeepingAwake: true)
        }
        XCTAssertEqual(resolve(attention: false, compact: true), .builtIn(.tools))
        XCTAssertEqual(resolve(attention: true, compact: true), .builtIn(.agent))
        XCTAssertEqual(resolve(attention: false, compact: false), .builtIn(.calendar))
    }

    func testDefaultsChangesDoNotOpenIslandPopoverAndDurationMenuHoldsPresentation() async throws {
        try await withToolsAsync { manager, state, _ in
            state.presentFullExpandedModule(.tools)
            let host = NSHostingView(rootView: ToolsView(manager: manager).environmentObject(state).frame(width: 578, height: 158))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 578, height: 158), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            _ = try await NativeUI.waitForElement(in: host, id: "keep-awake-duration")
            state.keepAwakeDuration = .custom
            _ = try await NativeUI.waitForElement(in: host, id: "keep-awake-edit-custom")
            await NativeUI.drainMainQueue()
            XCTAssertFalse(state.isControlInteractionActive, "Changing defaults must not open the island's editing popover")
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertTrue(state.isControlInteractionActive)
            state.dismiss()
            XCTAssertEqual(state.currentState, .fullExpanded)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            XCTAssertFalse(state.isControlInteractionActive)
        }
    }

    func testCustomDurationPopoverOpensBelowMinutesButtonAndKeepsIslandExpanded() async throws {
        try await withToolsAsync { manager, state, _ in
            state.keepAwakeDuration = .custom
            state.presentFullExpandedModule(.tools)
            let host = NSHostingView(rootView: ToolsView(manager: manager).environmentObject(state).frame(width: 578, height: 158))
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(contentRect: NSRect(x: screen.midX - 289, y: screen.midY, width: 578, height: 158),
                styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            let button = try await NativeUI.waitForElement(in: host, id: "keep-awake-edit-custom")
            let anchor = try NativeUI.frame(in: host, id: "keep-awake-edit-custom")
            XCTAssertEqual(button.accessibilityPerformPress?(), true)
            let popup = try await NativeUI.window(containing: "keep-awake-custom-minutes")
            try await NativeUI.waitFor("popover settles at the minutes button") {
                abs(popup.frame.midX - anchor.midX) < 12 && abs(popup.frame.maxY - anchor.minY) < 24
            }
            XCTAssertTrue(state.isControlInteractionActive)
            state.handleHoverChange(false)
            state.dismiss()
            XCTAssertEqual(state.currentState, .fullExpanded)
            let content = try XCTUnwrap(popup.contentView)
            let done = try await NativeUI.waitForElement(in: content, id: "keep-awake-custom-done")
            XCTAssertEqual(done.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("popover releases its presentation hold") {
                !popup.isVisible && !state.isControlInteractionActive
            }
        }
    }

    func testToolViewsFitHostBudgetAndCompactCountdownFitsMusicSideSlot() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/verification/tools")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let languageBefore = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer {
            if let languageBefore { UserDefaults.standard.set(languageBefore, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
        }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            try await withToolsAsync { manager, state, keyboard in
                state.presentFullExpandedModule(.tools)
                let contentWidth = Constants.fullExpandedSize.width - 2 * state.contentHorizontalPadding - 16
                for variant in ["tools", "custom", "forever", "permission", "locked"] {
                    manager.endCleaning()
                    manager.stopKeepingAwake()
                    keyboard.hasAccessibility = variant != "permission"
                    state.keepAwakeDuration = variant == "custom" ? .custom : .thirtyMinutes
                    if variant == "forever" { manager.startKeepingAwake(for: .forever) }
                    let locked = variant == "locked"
                    if locked { manager.startCleaning() }
                    let page = ToolsView(manager: manager).environmentObject(state)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .dark)
                        .frame(width: contentWidth)
                    let host = NSHostingView(rootView: page)
                    let budget = Constants.fullExpandedSize.height - FullExpandedLayout.shoulderTopPadding
                        - FullExpandedLayout.bottomPadding - FullExpandedLayout.moduleBottomPadding
                    XCTAssertLessThanOrEqual(host.fittingSize.height, budget)
                    // Native segmented controls are AppKit-backed; ImageRenderer draws a placeholder.
                    let snapshot = NSHostingView(rootView: page.frame(height: budget, alignment: .top).padding(8).background(Color.black))
                    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: contentWidth + 16, height: budget + 16),
                        styleMask: [], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = snapshot
                    window.orderFront(nil)
                    defer { window.contentView = nil; window.close() }
                    snapshot.layoutSubtreeIfNeeded()
                    await NativeUI.drainMainQueue()
                    _ = try await NativeUI.waitForElement(in: snapshot, id: locked ? "keyboard-cleaning-end" : "tools-awake-title")
                    let bitmap = try XCTUnwrap(snapshot.bitmapImageRepForCachingDisplay(in: snapshot.bounds))
                    snapshot.cacheDisplay(in: snapshot.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("\(language)-\(variant).png"))
                    if !locked {
                        if variant != "forever" {
                            let picker = try NativeUI.frame(in: snapshot, id: "keep-awake-duration")
                            XCTAssertLessThanOrEqual(picker.width, 136)
                        }
                        let awake = try NativeUI.frame(in: snapshot, id: "tools-awake-title")
                        let cleaning = try NativeUI.frame(in: snapshot, id: "tools-cleaning-title")
                        XCTAssertEqual(awake.minX, cleaning.minX, accuracy: 0.5)
                        let awakeAction = try NativeUI.frame(in: snapshot, id: variant == "forever" ? "keep-awake-stop" : "keep-awake-start")
                        let cleaningAction = try NativeUI.frame(in: snapshot, id: variant == "permission" ? "keyboard-cleaning-permission" : "keyboard-cleaning-start")
                        XCTAssertEqual(awakeAction.maxX, cleaningAction.maxX, accuracy: 0.5)
                    }
                }
                manager.endCleaning()
                state.keepAwakeDuration = .custom
                // Minimum settings width (800) minus sidebar, divider and page insets.
                for width: CGFloat in [551, 712] {
                    let settings = NSHostingView(rootView: ToolsSettingsDetail(manager: manager)
                        .environmentObject(state).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, .dark)
                        .frame(width: width).padding(24))
                    let size = settings.fittingSize
                    XCTAssertLessThan(size.height, 520)
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = settings
                    window.orderFront(nil)
                    defer { window.contentView = nil; window.close() }
                    settings.layoutSubtreeIfNeeded()
                    await NativeUI.drainMainQueue()
                    _ = try await NativeUI.waitForElement(in: settings, id: "tools-custom-minutes")
                    let field = try XCTUnwrap(NativeUI.nativeViews(in: settings).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "tools-custom-minutes" })
                    XCTAssertEqual(field.stringValue, "90")
                    let unit = try XCTUnwrap(NativeUI.find(in: settings, id: "tools-custom-minutes-unit"))
                    let textValue: String? = unit.accessibilityValue?()
                    let unitText = textValue ?? unit.accessibilityLabel?()
                    XCTAssertEqual(unitText, language == "zh-Hans" ? "分钟" : "minutes")
                    let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
                    settings.cacheDisplay(in: settings.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("\(language)-settings-\(Int(width)).png"))
                }
            }
        }
        let side = CompactSideLayout().contentWidth
        for remaining in [nil, 86400, 7200, 3600, 3599, 1] as [TimeInterval?] {
            let label = KeepAwakeCountdownLabel(remaining: remaining).fixedSize()
            XCTAssertLessThanOrEqual(NSHostingView(rootView: label).fittingSize.width, side)
        }
        for (name, remaining) in [("1-hour", 3600), ("24-hours", 86400), ("seconds", 3599), ("forever", nil)] as [(String, TimeInterval?)] {
            let compact = CompactSideSlots(centerGapWidth: 200, sideWidth: side,
                leading: AnyView(Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)),
                trailing: AnyView(KeepAwakeCountdownLabel(remaining: remaining)))
                .frame(width: 200 + side * 2, height: 32).background(Color.black)
            let renderer = ImageRenderer(content: compact)
            renderer.scale = 3
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("compact-\(name).png"))
        }
    }
}
