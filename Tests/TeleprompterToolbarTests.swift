import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class TeleprompterToolbarTests: XCTestCase {
    private enum ReadingState { case paused, playing, countdown, resume }
    private let sample = "First paragraph with enough text to wrap in a narrow column.\n第二段包含中文、数字 123 和 👋 表情。\nFinal paragraph."

    private func withFixture(mode: TeleprompterListeningMode = .classic, state: ReadingState = .paused,
                             script: String? = nil,
                             body: (TeleprompterManager, AppState, UserDefaults) async throws -> Void) async throws {
        let domain = "app.notchx.tests.prompter-toolbar.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let text = script ?? sample
        preferences.set(text, forKey: "teleprompter.script")
        preferences.set(mode.rawValue, forKey: SettingsDefaults.Teleprompter.listeningMode.key)
        preferences.set(10, forKey: SettingsDefaults.Teleprompter.countdown.key)
        preferences.set(true, forKey: "module.teleprompter.enabled")
        if state == .resume {
            TeleprompterSessionStore(preferences: preferences).savePosition(.init(script: text, displayOffset: 10, progress: 0.4))
        }
        let appState = AppState(preferenceStore: preferences)
        appState.currentState = .fullExpanded
        let manager = TeleprompterManager(preferences: preferences, appState: appState)
        manager.setEnabled(true)
        if state == .playing { manager.isPlaying = true }
        if state == .countdown { manager.play(); XCTAssertTrue(manager.isCountingDown) }
        defer {
            manager.setEnabled(false)
            appState.cancelAutoDismiss(); appState.cancelFullExpandedDismiss()
            preferences.removePersistentDomain(forName: domain)
        }
        try await body(manager, appState, preferences)
    }

    func testPrimaryControlsRemainSingleLineAndInsideBothLanguagesWidthsAndStates() async throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(original.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for mode in TeleprompterListeningMode.allCases {
                for state in [ReadingState.paused, .resume] {
                    for width: CGFloat in [320, 578] {
                        try await withFixture(mode: mode, state: state) { manager, appState, preferences in
                            let before = preferences.dictionaryRepresentation()
                            let host = NSHostingView(rootView: TeleprompterToolbar(manager: manager, editScript: {})
                                .environmentObject(appState).notchXLocalized())
                            let window = makeWindow(host, width: width, height: 100)
                            defer { window.close() }
                            _ = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-paragraph-control")
                            let edit = try NativeUI.frame(in: host, id: "data-annotation-id=teleprompter-edit-script-button")
                            let more = try NativeUI.frame(in: host, id: "data-annotation-id=teleprompter-more-control")
                            let paragraph = try NativeUI.frame(in: host, id: "data-annotation-id=teleprompter-paragraph-control", context: "\(language) \(mode) \(state) width=\(width)")
                            XCTAssertGreaterThanOrEqual(edit.width, 48, "\(language) \(mode) \(state) width=\(width): Edit compressed")
                            XCTAssertLessThanOrEqual(edit.height, 36, "Edit wrapped vertically")
                            XCTAssertLessThanOrEqual(edit.maxX, more.minX + 0.5)
                            XCTAssertLessThanOrEqual(paragraph.maxY, edit.minY + 0.5, "State row overlaps primary actions")
                            for element in NativeUI.elements(in: host) {
                                guard let role = element.accessibilityRole?(),
                                      [.button, .popUpButton, .menuButton, .staticText].contains(role),
                                      let rect = element.accessibilityFrame?(), rect.width > 0 else { continue }
                                XCTAssertGreaterThanOrEqual(rect.minX, window.frame.minX - 0.5)
                                XCTAssertLessThanOrEqual(rect.maxX, window.frame.maxX + 0.5, "\(language) \(mode) \(state) width=\(width): clipped control")
                            }
                            if state == .resume {
                                XCTAssertNotNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-resume-control"))
                                XCTAssertNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-play-control"))
                            } else {
                                let play = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-play-control"))
                                XCTAssertEqual(play.accessibilityLabel?(), L10n.text(state == .paused ? "Play" : "Pause"))
                            }
                            for key in [SettingsDefaults.Teleprompter.fontSize.key, SettingsDefaults.Teleprompter.alignment.key,
                                        SettingsDefaults.Teleprompter.scrollSpeed.key, SettingsDefaults.Teleprompter.listeningMode.key] {
                                XCTAssertEqual(preferences.object(forKey: key) as? NSObject, before[key] as? NSObject)
                            }
                        }
                    }
                }
            }
        }
    }

    func testFullPageReservesSeparateReadingViewportAndSimplifiesEmptyScript() async throws {
        for (empty, mode) in [(true, TeleprompterListeningMode.classic), (true, .wordTracking),
                              (false, .classic), (false, .wordTracking)] {
            for width: CGFloat in [320, 578] {
                try await withFixture(mode: mode, script: empty ? "" : sample) { manager, appState, _ in
                    let host = NSHostingView(rootView: TeleprompterFullExpandedInner(manager: manager)
                        .environmentObject(appState).notchXLocalized())
                    let window = makeWindow(host, width: width, height: 158)
                    defer { window.close() }
                    _ = try await NativeUI.waitForElement(in: host, id: "teleprompter-reading-viewport")
                    let reading = try NativeUI.frame(in: host, id: "teleprompter-reading-viewport")
                    if empty {
                        // The empty guidance uses the whole page, without
                        // reserving a phantom playback toolbar.
                        XCTAssertEqual(reading.midY, window.frame.midY, accuracy: 2)
                        XCTAssertNil(NativeUI.find(in: host, id: "teleprompter-toolbar"))
                        XCTAssertNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-more-control"))
                        XCTAssertNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-play-control"))
                        XCTAssertNotNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-edit-script-button"))
                        XCTAssertNotNil(NativeUI.find(in: host, id: "teleprompter-empty-title"))
                        XCTAssertNotNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-empty-settings-control"))
                    } else {
                        let toolbar = try NativeUI.frame(in: host, id: "teleprompter-toolbar")
                        XCTAssertGreaterThanOrEqual(toolbar.minY - window.frame.minY - 6, 60)
                        XCTAssertLessThanOrEqual(reading.maxY, toolbar.minY - 4)
                    }
                }
            }
        }
    }

    func testNativePlayButtonStartsAndCancelsCountdownAndPausesPlayback() async throws {
        for state in [ReadingState.paused, .playing, .countdown] {
            try await withFixture(state: state) { manager, appState, _ in
                let host = NSHostingView(rootView: TeleprompterToolbar(manager: manager, editScript: {}).environmentObject(appState))
                let window = makeWindow(host, width: 578, height: 100)
                defer { window.close() }
                let id = "data-annotation-id=teleprompter-play-control"
                let play = try await NativeUI.waitForElement(in: host, id: id)
                XCTAssertEqual(play.accessibilityLabel?(), L10n.text(state == .paused ? "Play" : "Pause"))
                XCTAssertEqual(play.accessibilityPerformPress?(), true)
                let expectedLabel = L10n.text(state == .paused ? "Pause" : "Play")
                try await NativeUI.waitFor("playback action and label", in: host) {
                    NativeUI.find(in: host, id: id)?.accessibilityLabel?() == expectedLabel
                }
                XCTAssertFalse(manager.isPlaying)
                XCTAssertEqual(manager.isCountingDown, state == .paused)
                XCTAssertFalse(manager.speechRecognizer.isListening)
            }
        }
    }

    func testCompactRecoveryEntryOffersBothChoicesWithoutStartingAudio() async throws {
        for mode in TeleprompterListeningMode.allCases {
            for startOver in [false, true] {
                try await withFixture(mode: mode, state: .resume) { manager, appState, _ in
                    appState.currentState = .expanded
                    let host = NSHostingView(rootView: TeleprompterExpandedView(manager: manager).environmentObject(appState).notchXLocalized())
                    let window = makeWindow(host, width: 408, height: 88)
                    defer { window.close() }
                    let entry = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-show-recovery-control")
                    XCTAssertNil(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-play-control"))
                    XCTAssertEqual(entry.accessibilityLabel?(), L10n.text("Continue Reading"))
                    XCTAssertEqual(entry.accessibilityPerformPress?(), true)
                    XCTAssertEqual(appState.currentState, .fullExpanded)
                    window.setContentSize(NSSize(width: 578, height: 158))
                    let choice = try await NativeUI.waitForElement(in: host, id: startOver
                        ? "data-annotation-id=teleprompter-start-over-control" : "data-annotation-id=teleprompter-resume-control")
                    XCTAssertEqual(manager.pendingResumePosition?.progress, 0.4)
                    XCTAssertFalse(manager.isPlaying)
                    XCTAssertFalse(manager.isCountingDown)
                    XCTAssertEqual(choice.accessibilityPerformPress?(), true)
                    XCTAssertNil(manager.pendingResumePosition)
                    XCTAssertFalse(manager.isPlaying)
                    XCTAssertFalse(manager.isCountingDown)
                    XCTAssertFalse(manager.speechRecognizer.isListening)
                    if startOver { XCTAssertNil(manager.sessionStore.position(for: manager.scriptText)) }
                    else { XCTAssertEqual(manager.seekRequest.displayOffset, 10) }
                }
            }
        }
    }

    func testEmptyGuidanceTracksDraftAndFitsBothLanguages() async throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(original.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for width: CGFloat in [320, 408, 578] {
                try await withFixture(script: "") { manager, appState, preferences in
                    var edits = 0
                    let host = NSHostingView(rootView: TeleprompterFullExpandedInner(manager: manager, editScript: { edits += 1 })
                        .environmentObject(appState).notchXLocalized())
                    let window = makeWindow(host, width: width, height: 158)
                    defer { window.close() }
                    for draft in [nil, "Saved 中文 draft", "", "  \n", nil] as [String?] {
                        if let draft { manager.sessionStore.saveDraft(draft) } else { manager.sessionStore.discardDraft() }
                        let hasDraft = !(draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        try await NativeUI.waitFor("draft entry wording", in: host) {
                            NativeUI.find(in: host, id: "data-annotation-id=teleprompter-edit-script-button")?.accessibilityLabel?() == L10n.text(hasDraft ? "Continue editing draft" : "Add script")
                        }
                        let button = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-edit-script-button"))
                        XCTAssertEqual(button.accessibilityLabel?(), L10n.text(hasDraft ? "Continue editing draft" : "Add script"))
                        XCTAssertEqual(button.accessibilityPerformPress?(), true)
                        XCTAssertFalse(manager.hasScript)
                        XCTAssertEqual(preferences.string(forKey: "teleprompter.script"), "")
                        XCTAssertEqual(manager.sessionStore.draft, draft)
                        for element in NativeUI.elements(in: host) {
                            guard let role = element.accessibilityRole?(), [.button, .staticText].contains(role),
                                  let rect = element.accessibilityFrame?(), rect.width > 0 else { continue }
                            XCTAssertGreaterThanOrEqual(rect.minX, window.frame.minX - 0.5, "\(language) width=\(width)")
                            XCTAssertLessThanOrEqual(rect.maxX, window.frame.maxX + 0.5, "\(language) width=\(width)")
                            XCTAssertGreaterThanOrEqual(rect.minY, window.frame.minY - 0.5)
                            XCTAssertLessThanOrEqual(rect.maxY, window.frame.maxY + 0.5)
                        }
                    }
                    XCTAssertEqual(edits, 5)
                }
            }
        }
    }

    func testEmptySettingsAdjustPreferencesWithoutReadingRecoveryAndCloseOnInactivity() async throws {
        for mode in TeleprompterListeningMode.allCases {
            try await withFixture(mode: mode, script: "") { manager, appState, _ in
                @MainActor func content(active: Bool) -> some View {
                    TeleprompterFullExpandedInner(manager: manager, editScript: {})
                        .environmentObject(appState).environment(\.islandContentActive, active).notchXLocalized()
                }
                let host = NSHostingView(rootView: content(active: true))
                let window = makeWindow(host, width: 320, height: 158)
                var popover: NSWindow?
                defer { popover?.close(); window.close() }
                _ = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-empty-settings-control")
                let settings = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-empty-settings-control"))
                XCTAssertEqual(settings.accessibilityPerformPress?(), true)
                popover = try await NativeUI.window(containing: "teleprompter-reading-options-title")
                let options = try XCTUnwrap(popover?.contentView)
                XCTAssertEqual(popover?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
                XCTAssertTrue(appState.isControlInteractionActive)
                XCTAssertNil(NativeUI.find(in: options, id: "teleprompter-restart-paragraph-control"))
                XCTAssertNil(NativeUI.find(in: options, id: "teleprompter-classic-recovery-control"))
                let font = try XCTUnwrap(NativeUI.find(in: options, id: "teleprompter-font-size-control"))
                let oldFont = manager.fontSize
                _ = font.accessibilityPerformIncrement?()
                try await NativeUI.waitFor("empty font change", in: options) { manager.fontSize == oldFont + 2 }
                XCTAssertEqual(manager.fontSize, oldFont + 2)
                XCTAssertNotNil(NativeUI.find(in: options, id: "teleprompter-alignment-control"))
                XCTAssertEqual(NativeUI.find(in: options, id: "teleprompter-scroll-speed-control") != nil, mode == .classic)
                XCTAssertFalse(manager.isPlaying)
                XCTAssertFalse(manager.speechRecognizer.isListening)
                host.rootView = content(active: false)
                try await NativeUI.waitFor("empty options dismissed", in: host) { !appState.isControlInteractionActive && popover?.isVisible == false }
                XCTAssertFalse(appState.isControlInteractionActive)
                XCTAssertFalse(popover?.isVisible ?? true)
            }
        }
    }

    func testMoreOpensDarkOptionsAndReleasesHostInteractionOnRecovery() async throws {
        try await withFixture(mode: .wordTracking) { manager, appState, _ in
            let target = manager.paragraphs[1].id
            manager.jumpToParagraph(target)
            manager.isPlaying = true
            let host = NSHostingView(rootView: TeleprompterToolbar(manager: manager, editScript: {})
                .environmentObject(appState).notchXLocalized())
            let window = makeWindow(host, width: 320, height: 100)
            var popover: NSWindow?
            defer { popover?.close(); window.close() }
            _ = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-more-control")
            let more = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-more-control"))
            XCTAssertEqual(more.accessibilityPerformPress?(), true)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertTrue(appState.isControlInteractionActive)
            popover = try await NativeUI.window(containing: "teleprompter-reading-options-title")
            let content = try XCTUnwrap(popover?.contentView)
            XCTAssertEqual(popover?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            XCTAssertNotNil(NativeUI.find(in: content, id: "teleprompter-font-size-control"))
            XCTAssertNotNil(NativeUI.find(in: content, id: "teleprompter-alignment-control"))
            XCTAssertNil(NativeUI.find(in: content, id: "teleprompter-scroll-speed-control"))
            let recover = try XCTUnwrap(NativeUI.find(in: content, id: "teleprompter-classic-recovery-control"))
            XCTAssertEqual(recover.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("reading recovery and popover close") { manager.listeningMode == .classic && !appState.isControlInteractionActive && popover?.isVisible == false }
            XCTAssertEqual(manager.listeningMode, .classic)
            XCTAssertEqual(manager.seekRequest.displayOffset, target)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertFalse(manager.speechRecognizer.isListening)
            XCTAssertFalse(appState.isControlInteractionActive)
        }
    }

    func testReadingOptionsKeepBindingsAndCloseWhenContentBecomesInactive() async throws {
        try await withFixture { manager, appState, _ in
            @MainActor func content(active: Bool) -> some View {
                TeleprompterToolbar(manager: manager, editScript: {})
                    .environmentObject(appState).environment(\.islandContentActive, active).notchXLocalized()
            }
            let host = NSHostingView(rootView: content(active: true))
            let window = makeWindow(host, width: 320, height: 100)
            var popover: NSWindow?
            defer { popover?.close(); window.close() }
            _ = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-more-control")
            let more = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-more-control"))
            XCTAssertEqual(more.accessibilityPerformPress?(), true)
            popover = try await NativeUI.window(containing: "teleprompter-reading-options-title")
            let options = try XCTUnwrap(popover?.contentView)
            let font = try XCTUnwrap(NativeUI.find(in: options, id: "teleprompter-font-size-control"))
            let originalFont = manager.fontSize
            _ = font.accessibilityPerformIncrement?()
            try await NativeUI.waitFor("font change", in: options) { manager.fontSize == originalFont + 2 }
            XCTAssertEqual(manager.fontSize, originalFont + 2)
            // Exercise the public native control's normal target/action path.
            let alignment = try XCTUnwrap(NativeUI.nativeViews(in: options).compactMap { $0 as? NSSegmentedControl }.first)
            alignment.selectedSegment = 0
            XCTAssertTrue(alignment.sendAction(alignment.action, to: alignment.target))
            try await NativeUI.waitFor("alignment selection", in: options) { manager.textAlignmentIndex == 0 }
            XCTAssertEqual(manager.textAlignmentIndex, 0)
            manager.textAlignmentIndex = 2
            try await NativeUI.waitFor("external alignment update", in: options) { alignment.selectedSegment == 2 }
            XCTAssertEqual(alignment.selectedSegment, 2, "External preference updates must reach the open picker")
            let speed = try XCTUnwrap(NativeUI.find(in: options, id: "teleprompter-scroll-speed-control"))
            let minimum = (speed.accessibilityMinValue?() as? NSNumber)?.doubleValue ?? 0
            let maximum = (speed.accessibilityMaxValue?() as? NSNumber)?.doubleValue ?? 1
            speed.setAccessibilityValue?(NSNumber(value: (minimum + maximum) / 2))
            try await NativeUI.waitFor("speed change", in: options) { abs(manager.scrollSpeed - 15.5) < 0.01 }
            XCTAssertEqual(manager.scrollSpeed, 15.5, accuracy: 0.01)
            XCTAssertTrue(appState.isControlInteractionActive)
            host.rootView = content(active: false)
            try await NativeUI.waitFor("inactive options dismissed", in: host) { !appState.isControlInteractionActive && popover?.isVisible == false }
            XCTAssertFalse(appState.isControlInteractionActive)
            XCTAssertFalse(popover?.isVisible ?? true)
        }
    }

    func testNarrowWideTransitionsKeepParagraphAndEditControlsVisible() async throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        UserDefaults.standard.setVolatileDomain(original.merging([L10n.preferenceKey: "en"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        try await withFixture(mode: .wordTracking) { manager, appState, _ in
            let host = NSHostingView(rootView: TeleprompterToolbar(manager: manager, editScript: {}).environmentObject(appState).notchXLocalized())
            let window = makeWindow(host, width: 578, height: 100)
            defer { window.close() }
            for width: CGFloat in [578, 320, 408, 578] {
                window.setContentSize(NSSize(width: width, height: 100))
                try await NativeUI.waitFor("paragraph fits resized window", in: host) {
                    guard let rect = NativeUI.find(in: host, id: "data-annotation-id=teleprompter-paragraph-control")?.accessibilityFrame?() else { return false }
                    return rect.width >= 20 && rect.maxX <= window.frame.maxX + 0.5
                }
                let paragraph = try NativeUI.frame(in: host, id: "data-annotation-id=teleprompter-paragraph-control")
                let edit = try NativeUI.frame(in: host, id: "data-annotation-id=teleprompter-edit-script-button")
                XCTAssertGreaterThan(paragraph.width, 20)
                XCTAssertGreaterThanOrEqual(edit.width, 48)
                XCTAssertLessThanOrEqual(paragraph.maxX, window.frame.maxX + 0.5)
            }
        }
    }

    private func makeWindow<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

}
