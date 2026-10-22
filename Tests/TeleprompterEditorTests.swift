import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class TeleprompterEditorTests: XCTestCase {
    private func withEditor(_ body: (TeleprompterManager, AppState, TeleprompterScriptEditorWindowController, UserDefaults, IslandPanel) async throws -> Void) async throws {
        let domain = "app.notchx.tests.prompter-editor.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        preferences.set(true, forKey: "module.teleprompter.enabled")
        preferences.set("Applied script", forKey: "teleprompter.script")
        let state = AppState(preferenceStore: preferences)
        state.selectFullExpandedTab(.module(.builtIn(.teleprompter)))
        state.currentState = .fullExpanded
        state.hoverExpandDelay = 0
        let manager = TeleprompterManager(preferences: preferences, appState: state)
        manager.setEnabled(true)
        let controller = TeleprompterScriptEditorWindowController(manager: manager, appState: state, preferences: preferences)
        let screen = try XCTUnwrap(NSScreen.main)
        let source = IslandPanel()
        source.isReleasedWhenClosed = false
        source.setFrame(NSRect(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.maxY - 220, width: 600, height: 220), display: false)
        source.orderFront(nil)
        defer {
            controller.close()
            source.close()
            manager.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            state.endSystemEmojiInteraction()
            preferences.removePersistentDomain(forName: domain)
        }
        try await body(manager, state, controller, preferences, source)
    }

    func testOpeningPausesCollapsesAndAllowsHoverWithoutPassiveHUDReplacement() async throws {
        for countingDown in [false, true] {
            try await withEditor { manager, state, controller, _, source in
                if countingDown {
                    manager.play()
                    XCTAssertTrue(manager.isCountingDown)
                } else { manager.isPlaying = true }
                state.isHovering = true
                controller.showEditor(sourceWindow: source, activateApplication: false)
                try await NativeUI.waitFor("editor input focus") { controller.window?.firstResponder is NSTextView }
                XCTAssertFalse(manager.isPlaying)
                XCTAssertFalse(manager.isCountingDown)
                XCTAssertFalse(manager.speechRecognizer.isListening)
                XCTAssertEqual(state.currentState, .compact)
                XCTAssertNotNil(state.presentationHandoffs.values.first)
                let window = try XCTUnwrap(controller.window)
                XCTAssertTrue(window.firstResponder is NSTextView)
                controller.showEditor(sourceWindow: source, activateApplication: false)
                XCTAssertTrue(controller.window === window)
                state.handlePointerSample(hovering: true, moved: false)
                state.showHUD(module: .volumeHUD)
                await NativeUI.drainMainQueue()
                XCTAssertEqual(state.currentState, .compact)
                state.handlePointerSample(hovering: true, moved: true)
                try await NativeUI.waitFor("hover works while editor stays open") { state.currentState == .fullExpanded }
                XCTAssertTrue(window.isVisible)
                window.performClose(nil)
                await NativeUI.drainMainQueue()
                XCTAssertEqual(state.currentState, .fullExpanded, "Closing the editor preserves the later hover presentation")
            }
        }
    }

    func testReadingPopoverHandsOffToEditorAndReleasesInteractionWithEitherLockState() async throws {
        for locked in [false, true] {
            try await withEditor { manager, state, controller, _, source in
                state.lockFullExpandedInPlace = locked
                state.isHovering = true
                let host = NSHostingView(rootView: TeleprompterFullExpandedInner(manager: manager) {
                    controller.showEditor(sourceWindow: source, activateApplication: false)
                }.environmentObject(state).notchXLocalized())
                source.contentView = host
                let more = try await NativeUI.waitForElement(in: host, id: "data-annotation-id=teleprompter-more-control")
                XCTAssertEqual(more.accessibilityPerformPress?(), true)
                let popover = try await NativeUI.window(containing: "teleprompter-reading-options-title")
                defer { popover.close() }
                XCTAssertTrue(state.isControlInteractionActive)
                let edit = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=teleprompter-edit-script-button"))
                XCTAssertEqual(edit.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("popover hands off without a retained hold", in: host) {
                    !state.isControlInteractionActive && !popover.isVisible && controller.window?.firstResponder is NSTextView
                }
                XCTAssertEqual(state.currentState, locked ? .fullExpanded : .compact)
                XCTAssertEqual(state.lockFullExpandedInPlace, locked)
                XCTAssertNotNil(state.presentationHandoffs.values.first)
                XCTAssertFalse(manager.isPlaying)
                XCTAssertFalse(manager.speechRecognizer.isListening)
            }
        }
    }

    func testNativeEditingCloseRestoresDraftAndDoneReturnsPaused() async throws {
        try await withEditor { manager, state, controller, _, source in
            controller.showEditor(sourceWindow: source, activateApplication: false)
            try await NativeUI.waitFor("editor input focus") { controller.window?.firstResponder is NSTextView }
            let window = try XCTUnwrap(controller.window)
            let textView = try XCTUnwrap(NativeUI.nativeViews(in: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextView }.first)
            let draft = "Edited 中文 draft 👋"
            textView.insertText(draft, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
            try await NativeUI.waitFor("native text saves draft") { manager.sessionStore.draft == draft }
            XCTAssertEqual(manager.sessionStore.draft, draft)
            XCTAssertEqual(manager.scriptText, "Applied script")
            window.performClose(nil)
            XCTAssertNil(controller.window)
            XCTAssertNil(state.presentationHandoffs.values.first)
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertEqual(manager.sessionStore.draft, draft)
            controller.showEditor(sourceWindow: source, activateApplication: false)
            try await NativeUI.waitFor("reopened draft") {
                controller.window?.contentView.flatMap { NativeUI.nativeViews(in: $0).compactMap { $0 as? NSTextView }.first }?.string == draft
            }
            let reopened = try XCTUnwrap(controller.window?.contentView)
            XCTAssertEqual(NativeUI.nativeViews(in: reopened).compactMap { $0 as? NSTextView }.first?.string, draft)
            let done = try XCTUnwrap(NativeUI.elements(in: reopened).first { $0.accessibilityIdentifier?() == "data-annotation-id=teleprompter-editor-done-control" })
            XCTAssertEqual(done.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("editor closed") { controller.window == nil }
            XCTAssertNil(controller.window)
            XCTAssertNil(state.presentationHandoffs.values.first)
            XCTAssertEqual(manager.scriptText, draft)
            XCTAssertNil(manager.sessionStore.draft)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertFalse(manager.isCountingDown)
            XCTAssertFalse(manager.speechRecognizer.isListening)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.teleprompter)))
        }
    }

    func testLockedIslandStaysOpenAndEditorFitsBelowSourcePanel() async throws {
        try await withEditor { _, state, controller, _, source in
            state.lockFullExpandedInPlace = true
            controller.showEditor(sourceWindow: source, activateApplication: false)
            try await NativeUI.waitFor("locked editor input focus") { controller.window?.firstResponder is NSTextView }
            let editor = try XCTUnwrap(controller.window)
            let visible = try XCTUnwrap(source.screen).visibleFrame
            XCTAssertTrue(state.lockFullExpandedInPlace)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertLessThanOrEqual(editor.frame.maxY, source.frame.minY - 12 + 0.5)
            XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(editor.frame))
            editor.performClose(nil)
            XCTAssertTrue(state.lockFullExpandedInPlace)
            XCTAssertEqual(state.currentState, .fullExpanded)
        }
    }

    func testReopeningRestoresAdjustedWindowFrame() async throws {
        try await withEditor { _, _, controller, preferences, source in
            controller.showEditor(sourceWindow: source, activateApplication: false)
            let window = try XCTUnwrap(controller.window)
            let visible = try XCTUnwrap(source.screen).visibleFrame
            let desired = NSRect(x: visible.minX + 25, y: visible.minY + 25,
                                 width: min(640, visible.width - 50), height: min(500, visible.height - 50))
            window.setFrame(desired, display: false)
            window.performClose(nil)
            XCTAssertEqual(preferences.string(forKey: "teleprompter.editor.frame").map(NSRectFromString), desired)
            controller.showEditor(sourceWindow: source, activateApplication: false)
            XCTAssertEqual(controller.window?.frame, desired)
        }
    }

    func testDisableClosesEditorAndStaleCompletionCannotReopen() async throws {
        try await withEditor { manager, state, controller, _, source in
            manager.sessionStore.saveDraft("Retained draft")
            controller.showEditor(sourceWindow: source, activateApplication: false)
            let old = try XCTUnwrap(state.presentationHandoffs.values.first)
            state.teleprompterEnabled = false
            state.reconcileEnabledModules()
            try await NativeUI.waitFor("editor closed") { controller.window == nil }
            XCTAssertNil(controller.window)
            XCTAssertNil(state.presentationHandoffs.values.first)
            XCTAssertEqual(manager.sessionStore.draft, "Retained draft")
            XCTAssertEqual(manager.scriptText, "Applied script")
            XCTAssertEqual(state.currentState, .compact)
            state.teleprompterEnabled = true
            let fresh = try XCTUnwrap(state.beginPresentationHandoff(.window, for: .teleprompter, returnsToSource: true))
            state.finishPresentationHandoff(old, outcome: .completed)
            XCTAssertEqual(state.presentationHandoffs.values.first?.id, fresh.id)
            XCTAssertEqual(state.currentState, .compact)
            state.finishPresentationHandoff(fresh, outcome: .cancelled)
        }
    }

    func testReactivationReusesDraftAndRenewsReturnIntentAfterUnlock() async throws {
        try await withEditor { manager, state, controller, _, source in
            state.lockFullExpandedInPlace = true
            controller.showEditor(sourceWindow: source, activateApplication: false)
            try await NativeUI.waitFor("editor input focus") { controller.window?.firstResponder is NSTextView }
            let window = try XCTUnwrap(controller.window)
            let content = try XCTUnwrap(window.contentView)
            let textView = try XCTUnwrap(NativeUI.nativeViews(in: content).compactMap { $0 as? NSTextView }.first)
            let draft = "Retained draft across activation"
            textView.insertText(draft, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
            try await NativeUI.waitFor("draft saved") { manager.sessionStore.draft == draft }
            let old = try XCTUnwrap(state.presentationHandoffs.values.first(where: { $0.module == .teleprompter }))
            state.lockFullExpandedInPlace = false
            state.presentFullExpandedModule(.teleprompter)
            controller.showEditor(sourceWindow: source, activateApplication: false)
            XCTAssertTrue(controller.window === window)
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            XCTAssertFalse(state.isPresentationHandoffActive(old))
            state.finishPresentationHandoff(old, outcome: .completed)
            XCTAssertEqual(textView.string, draft)
            let done = try XCTUnwrap(NativeUI.find(in: content, id: "data-annotation-id=teleprompter-editor-done-control"))
            XCTAssertEqual(done.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("reactivated editor returns to reading") { controller.window == nil && state.currentState == .fullExpanded }
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.teleprompter)))
            XCTAssertEqual(manager.scriptText, draft)
            XCTAssertFalse(manager.isPlaying)
        }
    }

    func testPlacementClampsSavedDisconnectedAndOversizedFramesIncludingLockedScreens() {
        let visible = NSRect(x: 0, y: 30, width: 1280, height: 770)
        let size = NSSize(width: 560, height: 490)
        let first = IslandWindowPlacement.frame(size: size, savedFrame: nil, visibleFrame: visible, islandFrame: nil, minimumSize: NSSize(width: 400, height: 340))
        XCTAssertEqual(first.size, size)
        XCTAssertEqual(first.midX, visible.midX, accuracy: 0.01)
        XCTAssertEqual(first.midY, visible.midY + visible.height * 0.08, accuracy: 0.01)
        let saved = NSRect(x: 100, y: 80, width: 600, height: 520)
        XCTAssertEqual(IslandWindowPlacement.frame(size: size, savedFrame: saved, visibleFrame: visible, islandFrame: nil, minimumSize: NSSize(width: 400, height: 340)), saved)
        for visible in [NSRect(x: 0, y: 30, width: 1280, height: 770),
                        NSRect(x: -1440, y: 100, width: 1440, height: 900),
                        NSRect(x: 1280, y: -800, width: 800, height: 600)] {
            for locked in [false, true] {
                let island = locked ? NSRect(x: visible.midX - 300, y: visible.maxY - 220, width: 600, height: 220) : nil
                for saved in [nil, NSRect(x: 20000, y: 10000, width: 560, height: 490),
                              NSRect(x: visible.minX - 20, y: visible.minY - 20, width: 2000, height: 1600)] as [NSRect?] {
                    let result = IslandWindowPlacement.frame(size: NSSize(width: 560, height: 490),
                        savedFrame: saved, visibleFrame: visible, islandFrame: island, minimumSize: NSSize(width: 400, height: 340))
                    XCTAssertTrue(visible.contains(result))
                    XCTAssertGreaterThan(result.height, 0)
                    if let island { XCTAssertLessThanOrEqual(result.maxY, island.minY - 12) }
                }
            }
        }
    }

}
