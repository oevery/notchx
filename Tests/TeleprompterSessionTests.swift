import XCTest
@testable import NotchX

@MainActor
private final class ShortcutRegistrationProbe: TeleprompterShortcutControlling {
    var enabled = false
    var failRegistration = false
    var action: ((TeleprompterKeyboardAction) -> Void)?
    func apply(enabled: Bool, modifiers: TeleprompterShortcutModifiers, action: @escaping (TeleprompterKeyboardAction) -> Void) -> Bool {
        self.enabled = enabled
        self.action = action
        return !enabled || !failRegistration
    }
}

@MainActor
final class TeleprompterSessionTests: XCTestCase {
    func testHeldGlobalHotkeyDoesNotRepeatedlyTogglePlayback() {
        var state = TeleprompterShortcutPressState()
        XCTAssertTrue(state.shouldFire(id: 1, pressed: true))
        XCTAssertFalse(state.shouldFire(id: 1, pressed: true))
        XCTAssertTrue(state.shouldFire(id: 2, pressed: true))
        XCTAssertFalse(state.shouldFire(id: 1, pressed: false))
        XCTAssertTrue(state.shouldFire(id: 1, pressed: true))
    }
    private func withPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let domain = "app.notchx.tests.prompter.session.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        try body(preferences)
    }

    func testDraftSurvivesReopeningAndNeverOverwritesAppliedScript() {
        withPreferences { preferences in
            preferences.set("Applied", forKey: "teleprompter.script")
            let store = TeleprompterSessionStore(preferences: preferences)
            store.saveDraft("Unsaved 中文 👋")
            let reopened = TeleprompterSessionStore(preferences: preferences)
            XCTAssertEqual(reopened.draft, "Unsaved 中文 👋")
            XCTAssertEqual(preferences.string(forKey: "teleprompter.script"), "Applied")
            reopened.saveDraft("")
            XCTAssertEqual(store.draft, "", "An intentionally empty draft is not the applied script")
            reopened.discardDraft()
            XCTAssertNil(store.draft)
        }
    }

    func testCheckpointRejectsEditedScriptAndInvalidOffsets() {
        withPreferences { preferences in
            let store = TeleprompterSessionStore(preferences: preferences)
            let script = "中文 👋\r\n第二段"
            let position = TeleprompterReadingPosition(script: script, displayOffset: 5, progress: 0.6)
            store.savePosition(position)
            XCTAssertEqual(store.position(for: script), position)
            XCTAssertNil(store.position(for: script + "edited"))
            store.savePosition(.init(script: script, displayOffset: 1000, progress: 0.6))
            XCTAssertNil(store.position(for: script))
        }
    }

    func testManagerRestoresPausedPositionAndKeepsDraftAcrossReset() {
        withPreferences { preferences in
            let script = "First paragraph\n第二段 👋\nFinal"
            preferences.set(script, forKey: "teleprompter.script")
            let store = TeleprompterSessionStore(preferences: preferences)
            store.saveDraft("separate draft")
            let offset = TeleprompterParagraph.parse(script)[1].id
            store.savePosition(.init(script: script, displayOffset: offset, progress: 0.45))
            let manager = TeleprompterManager(preferences: preferences, appState: AppState(preferenceStore: preferences))
            defer { manager.setEnabled(false) }
            XCTAssertNotNil(manager.pendingResumePosition)
            manager.reportProgress(0)
            XCTAssertEqual(store.position(for: script)?.progress, 0.45)
            manager.resumeSavedPosition()
            XCTAssertNil(manager.pendingResumePosition)
            XCTAssertEqual(manager.seekRequest.displayOffset, offset)
            XCTAssertEqual(manager.seekRequest.progress, 0.45)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertFalse(manager.speechRecognizer.isListening)
            XCTAssertFalse(manager.isCountingDown)
            manager.reset()
            XCTAssertNil(store.position(for: script))
            XCTAssertEqual(store.draft, "separate draft")
        }
    }

    func testReadingRecoveryKeepsSelectedParagraphWithoutStartingAudio() {
        withPreferences { preferences in
            preferences.set(TeleprompterListeningMode.wordTracking.rawValue, forKey: SettingsDefaults.Teleprompter.listeningMode.key)
            let manager = TeleprompterManager(preferences: preferences, appState: AppState(preferenceStore: preferences))
            manager.setEnabled(true)
            defer { manager.setEnabled(false) }
            let script = "First paragraph\n第二段 👋\nFinal"
            manager.setScript(script)
            let paragraph = manager.paragraphs[1]
            manager.jumpToParagraph(paragraph.id)
            manager.restartCurrentParagraph()
            XCTAssertEqual(manager.seekRequest.displayOffset, paragraph.id)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertFalse(manager.speechRecognizer.isListening)
            XCTAssertEqual(manager.speechRecognizer.recognizedCharCount, paragraph.id)
            manager.switchToClassicAtCurrentPosition()
            XCTAssertEqual(manager.listeningMode, .classic)
            XCTAssertEqual(manager.seekRequest.displayOffset, paragraph.id)
            XCTAssertFalse(manager.speechRecognizer.isListening)
        }
    }

    func testClassicPauseCaptureAndManagerReloadKeepReadingFraction() {
        withPreferences { preferences in
            let manager = TeleprompterManager(preferences: preferences, appState: AppState(preferenceStore: preferences))
            manager.setScript("First\nSecond\nThird")
            manager.reportProgress(0.57, paragraphOffset: manager.paragraphs[1].id)
            manager.pause()
            XCTAssertEqual(manager.seekRequest.progress, 0.57)
            manager.captureClassicViewPosition()
            XCTAssertEqual(manager.seekRequest.progress, 0.57)
            let reopened = TeleprompterManager(preferences: preferences, appState: AppState(preferenceStore: preferences))
            XCTAssertEqual(reopened.pendingResumePosition?.progress, 0.57)
        }
    }

    func testGlobalShortcutsRespectOptInDisableAndRestoredDefaults() {
        withPreferences { preferences in
            let probe = ShortcutRegistrationProbe()
            let manager = TeleprompterManager(preferences: preferences, globalShortcuts: probe, appState: AppState(preferenceStore: preferences))
            manager.setEnabled(true)
            XCTAssertFalse(probe.enabled)
            manager.globalShortcutsEnabled = true
            XCTAssertTrue(probe.enabled)
            let activeAction = probe.action
            let speed = manager.scrollSpeed
            activeAction?(.faster)
            XCTAssertEqual(manager.scrollSpeed, speed + 1)
            manager.setEnabled(false)
            XCTAssertFalse(probe.enabled)
            activeAction?(.faster)
            XCTAssertEqual(manager.scrollSpeed, speed + 1, "A stale OS callback must be ignored")
            manager.setEnabled(true)
            XCTAssertTrue(probe.enabled)
            preferences.set(false, forKey: SettingsDefaults.Teleprompter.globalShortcuts.key)
            manager.reloadRestoredPreferences()
            XCTAssertFalse(probe.enabled)
            XCTAssertFalse(manager.globalShortcutsEnabled)
            manager.setEnabled(false)
        }
    }

    func testGlobalPlayWithPendingPositionPresentsRecoveryAndRemainsPausedInBothModes() {
        for mode in TeleprompterListeningMode.allCases {
            withPreferences { preferences in
                let script = "First paragraph\nSecond paragraph"
                preferences.set(script, forKey: "teleprompter.script")
                preferences.set(true, forKey: "module.teleprompter.enabled")
                preferences.set(mode.rawValue, forKey: SettingsDefaults.Teleprompter.listeningMode.key)
                TeleprompterSessionStore(preferences: preferences).savePosition(.init(script: script, displayOffset: 16, progress: 0.5))
                let appState = AppState(preferenceStore: preferences)
                let probe = ShortcutRegistrationProbe()
                let manager = TeleprompterManager(preferences: preferences, globalShortcuts: probe, appState: appState)
                manager.setEnabled(true)
                manager.globalShortcutsEnabled = true
                defer {
                    manager.setEnabled(false)
                    appState.cancelAutoDismiss(); appState.cancelFullExpandedDismiss(); appState.endSystemEmojiInteraction()
                }
                probe.action?(.playPause)
                XCTAssertEqual(appState.currentState, .fullExpanded)
                XCTAssertEqual(appState.fullExpandedSelectedTab, .module(.builtIn(.teleprompter)))
                XCTAssertNotNil(manager.pendingResumePosition)
                XCTAssertFalse(manager.isPlaying)
                XCTAssertFalse(manager.isCountingDown)
                XCTAssertFalse(manager.speechRecognizer.isListening)
            }
        }
    }

    func testHotkeyConflictIsReportedAndDisablingClearsIt() {
        withPreferences { preferences in
            let probe = ShortcutRegistrationProbe()
            probe.failRegistration = true
            let manager = TeleprompterManager(preferences: preferences, globalShortcuts: probe, appState: AppState(preferenceStore: preferences))
            manager.setEnabled(true)
            manager.globalShortcutsEnabled = true
            XCTAssertTrue(manager.globalShortcutConflict)
            manager.globalShortcutsEnabled = false
            XCTAssertFalse(manager.globalShortcutConflict)
            XCTAssertFalse(probe.enabled)
            manager.setEnabled(false)
        }
    }
}
